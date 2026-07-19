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
        memoryPercent: Float = 40,
        rx: UInt64 = 0,
        tx: UInt64 = 0
    ) -> Termmesh_Peer_V1_HostStats {
        var stats = Termmesh_Peer_V1_HostStats()
        stats.load1M = load
        stats.memoryPercent = memoryPercent
        stats.netRxBytesPerSec = rx
        stats.netTxBytesPerSec = tx
        return stats
    }

    func testSummaryLeadsWithLoad() {
        let summary = PeerHostStats(wire(load: 1.25)).summary

        // One decimal: the second one is noise at this refresh rate, and
        // the titlebar pays for every character.
        XCTAssertTrue(summary.hasPrefix("load 1.2"), "got \(summary)")
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
}
