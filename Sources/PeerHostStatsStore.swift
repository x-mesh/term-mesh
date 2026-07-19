import Foundation
import PeerProto

/// How loaded a peer host is, in the form the titlebar draws.
///
/// The string is built once here rather than at draw time on purpose: the
/// titlebar refresh is a measured hot path with a hang history behind it
/// (TERM-MESH-1K/1N), so the work it does per update has to stay down to
/// reading a value someone else already computed.
struct PeerHostStats: Equatable, Sendable {
    /// Ready to concatenate: `load 1.2  mem 45%  ↓2.1M ↑1.0M`.
    let summary: String
    /// When the host's sample arrived. A stale one is worse than none —
    /// a frozen number reads as a calm machine rather than a lost link.
    let receivedAt: Date

    /// Past this, the host has missed several of its own sampling ticks
    /// (it samples every ~2s) and whatever we hold no longer describes it.
    static let staleAfter: TimeInterval = 15

    var isStale: Bool { Date().timeIntervalSince(receivedAt) > Self.staleAfter }

    init(_ wire: Termmesh_Peer_V1_HostStats, receivedAt: Date = Date()) {
        var parts: [String] = []
        // Load first: it is the one number that says "this machine is
        // struggling" regardless of what it is struggling with.
        parts.append("load \(Self.oneDecimal(wire.load1M))")
        if wire.memoryPercent > 0 {
            parts.append("mem \(Int(wire.memoryPercent.rounded()))%")
        }
        // Only when something is actually moving — an idle host would
        // otherwise carry two permanent `↓0B ↑0B` that never mean anything.
        if wire.netRxBytesPerSec > 0 || wire.netTxBytesPerSec > 0 {
            parts.append("↓\(Self.rate(wire.netRxBytesPerSec)) ↑\(Self.rate(wire.netTxBytesPerSec))")
        }
        self.summary = parts.joined(separator: "  ")
        self.receivedAt = receivedAt
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Bytes/sec at titlebar width: two significant figures at most, and
    /// no unit longer than one character.
    private static func rate(_ bytesPerSecond: UInt64) -> String {
        let value = Double(bytesPerSecond)
        switch value {
        case 0..<1_000: return "\(bytesPerSecond)B"
        case 1_000..<1_000_000: return String(format: "%.0fK", value / 1_000)
        case 1_000_000..<1_000_000_000: return String(format: "%.1fM", value / 1_000_000)
        default: return String(format: "%.1fG", value / 1_000_000_000)
        }
    }
}

/// The latest stats for each peer host, shared by every workspace attached
/// to that host.
///
/// Keyed by host rather than by workspace or pane because the numbers
/// describe a machine: two workspaces on the same box would otherwise hold
/// two copies of one fact and disagree whenever one of them updated first.
@MainActor
final class PeerHostStatsStore: ObservableObject {
    static let shared = PeerHostStatsStore()

    /// Bumped on every stored sample. The titlebar observes this instead of
    /// the dictionary so it never reads host state off the hot path — see
    /// `PeerHostStats.summary`.
    @Published private(set) var generation: UInt64 = 0

    private var byHost: [PeerPaneHostKey: PeerHostStats] = [:]

    private init() {}

    func record(_ stats: Termmesh_Peer_V1_HostStats, for host: PeerPaneHostKey) {
        byHost[host] = PeerHostStats(stats)
        generation &+= 1
    }

    /// The host's latest stats, or nil when none arrived or the last one
    /// aged out. Callers render nothing rather than something stale.
    func stats(for host: PeerPaneHostKey) -> PeerHostStats? {
        guard let stats = byHost[host], !stats.isStale else { return nil }
        return stats
    }

    /// Drop a host's stats when nothing is connected to it any more, so a
    /// reconnect starts from the host's next real sample instead of showing
    /// numbers from the previous session.
    func forget(_ host: PeerPaneHostKey) {
        guard byHost.removeValue(forKey: host) != nil else { return }
        generation &+= 1
    }
}
