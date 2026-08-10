import Foundation
import PeerProto

/// How loaded a peer host is, in the form the titlebar draws.
///
/// The string is built once here rather than at draw time on purpose: the
/// titlebar refresh is a measured hot path with a hang history behind it
/// (TERM-MESH-1K/1N), so the work it does per update has to stay down to
/// reading a value someone else already computed.
struct PeerHostStats: Equatable, Sendable {
    /// The groups, in reading order, each already rendered.
    ///
    /// Kept apart rather than joined into one string so the titlebar can
    /// drop them one at a time as the window narrows. A single string can
    /// only be truncated mid-word, which would cut the last group in half
    /// and leave something unreadable behind.
    let groups: [Group]
    /// When the host's sample arrived. A stale one is worse than none —
    /// a frozen number reads as a calm machine rather than a lost link.
    let receivedAt: Date

    /// One labelled reading. `dropPriority` orders what goes first when
    /// there is not enough room: lower drops earlier.
    struct Group: Equatable, Sendable {
        let text: String
        let dropPriority: Double
    }

    /// Past this, the host has missed several of its own sampling ticks
    /// (it samples every ~2s) and whatever we hold no longer describes it.
    static let staleAfter: TimeInterval = 15

    var isStale: Bool { Date().timeIntervalSince(receivedAt) > Self.staleAfter }

    /// Everything on one line, for logs and tests.
    var summary: String { groups.map(\.text).joined(separator: "  ") }

    /// Free space on the peer, when it reported any.
    ///
    /// Separate from `groups` because this is the one reading a person needs
    /// before the machine stops being usable — agent checkouts and their build
    /// output are what fill a peer up — so it gets its own badge rather than
    /// competing for titlebar width.
    let diskAvailableBytes: UInt64
    let diskTotalBytes: UInt64

    /// True when the peer is close enough to full that the next checkout or
    /// build is at risk. A host that reports no capacity at all (an older
    /// build, or one that cannot measure it) is never "low" — showing a
    /// warning for a machine we know nothing about is worse than silence.
    var isDiskLow: Bool {
        guard diskTotalBytes > 0 else { return false }
        if diskAvailableBytes < 5 * 1024 * 1024 * 1024 { return true }
        return Double(diskAvailableBytes) / Double(diskTotalBytes) < 0.10
    }

    /// Free space rendered for a badge, or nil when the host did not report.
    var diskFreeText: String? {
        guard diskTotalBytes > 0 else { return nil }
        return "\(Self.capacity(diskAvailableBytes)) free"
    }

    /// Sidebar badge content, precomputed before constructing a host row so
    /// unrelated view transactions do not make every row query the shared
    /// stats store again.
    var diskWarningText: String? {
        guard isDiskLow else { return nil }
        return diskFreeText
    }

    /// Whether two samples would draw the same, ignoring `receivedAt`.
    ///
    /// Deliberately not `Equatable`: `==` includes the timestamp, which differs
    /// on every sample and would make this comparison always false. Everything
    /// a view can see is covered — the rendered groups, and the disk figures
    /// behind the sidebar badge.
    static func rendersIdentically(_ a: PeerHostStats?, _ b: PeerHostStats?) -> Bool {
        guard let a, let b else { return false }
        return a.groups == b.groups
            && a.diskAvailableBytes == b.diskAvailableBytes
            && a.diskTotalBytes == b.diskTotalBytes
    }

    init(_ wire: Termmesh_Peer_V1_HostStats, receivedAt: Date = Date()) {
        var groups: [Group] = []
        // Three figures, not one: the first says how busy the machine is,
        // the other two say whether that is a spike or a trend. Kept
        // together as one group because reading them apart means nothing.
        groups.append(
            Group(
                text: "load \(Self.oneDecimal(wire.load1M)) \(Self.oneDecimal(wire.load5M)) \(Self.oneDecimal(wire.load15M))",
                dropPriority: 0
            )
        )
        if wire.memoryPercent > 0 {
            groups.append(Group(text: "mem \(Int(wire.memoryPercent.rounded()))%", dropPriority: -1))
        }
        // Network before disk: a remote pane's responsiveness rides on the
        // link, so it is the one a person reaches for first.
        if wire.netRxBytesPerSec > 0 || wire.netTxBytesPerSec > 0 {
            groups.append(
                Group(
                    text: "net ↓\(Self.rate(wire.netRxBytesPerSec)) ↑\(Self.rate(wire.netTxBytesPerSec))",
                    dropPriority: -2
                )
            )
        }
        // Read/write rather than arrows: ↓↑ already mean "over the wire"
        // one group to the left, and reusing them here would read as more
        // network traffic.
        if wire.diskReadBytesPerSec > 0 || wire.diskWriteBytesPerSec > 0 {
            groups.append(
                Group(
                    text: "agent io \(Self.rate(wire.diskReadBytesPerSec))/\(Self.rate(wire.diskWriteBytesPerSec))",
                    dropPriority: -3
                )
            )
        }
        self.groups = groups
        self.receivedAt = receivedAt
        self.diskTotalBytes = wire.diskTotalBytes
        self.diskAvailableBytes = wire.diskAvailableBytes
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Absolute capacity, in the units people use for disks (GB, not GiB).
    private static func capacity(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        switch value {
        case 0..<1_000_000_000: return String(format: "%.0fMB", value / 1_000_000)
        case 1_000_000_000..<1_000_000_000_000: return String(format: "%.1fGB", value / 1_000_000_000)
        default: return String(format: "%.1fTB", value / 1_000_000_000_000)
        }
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

    /// Stores a host's sample, and publishes only when what the UI draws
    /// actually differs.
    ///
    /// The sample itself is always stored, because `receivedAt` is what keeps
    /// `stats(for:)` from serving a stale reading. But `receivedAt` changes on
    /// every sample by definition, so publishing on it would invalidate every
    /// observer of this store twice a minute per host regardless of whether a
    /// single rendered figure moved — and the comparison the titlebar already
    /// performs (`ContentView`'s `titlebarHostStats != hostStats`) would then
    /// discard the result. The sidebar has no such guard: it observes this
    /// store directly, so a host that has been sitting at the same load for
    /// minutes was re-evaluating its rows anyway.
    ///
    /// A host coming back from stale always publishes: its groups are
    /// unchanged by definition (the same numbers it went quiet on), but the
    /// stale state itself is what the view was last told about.
    func record(
        _ stats: Termmesh_Peer_V1_HostStats,
        for host: PeerPaneHostKey,
        receivedAt: Date = Date()
    ) {
        let previous = byHost[host]
        let next = PeerHostStats(stats, receivedAt: receivedAt)
        byHost[host] = next
        let wasStale = previous?.isStale ?? true
        guard wasStale || !PeerHostStats.rendersIdentically(previous, next) else { return }
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
