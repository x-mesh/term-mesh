import Foundation

/// Refuses a delegation when the disk the worker builds on is nearly full.
///
/// Every worker builds in its own worktree, so a delegation is also a claim on
/// disk. Once the disk fills, every worker's build fails at once, so the leader
/// is told before the task exists rather than after the builds break.
enum DelegateDiskGate {
    static let minimumFreeGBKey = "agentWorkers.delegateMinFreeDiskGB"
    static let defaultMinimumFreeGB = 5

    /// Decimal gigabytes, the unit `DiskSpace.capacity` shows.
    private static let bytesPerGB: UInt64 = 1_000_000_000

    /// The stored minimum, or the default when nothing was stored. 0 turns the
    /// gate off.
    static func minimumFreeGB(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: minimumFreeGBKey) != nil else { return defaultMinimumFreeGB }
        return max(0, defaults.integer(forKey: minimumFreeGBKey))
    }

    struct Refusal: Equatable {
        let availableBytes: UInt64
        let minimumBytes: UInt64
    }

    /// A disk that could not be measured is never refused: blocking every
    /// delegation on a missing reading would be worse than the risk it guards.
    static func refusal(availableBytes: UInt64?, minimumGB: Int) -> Refusal? {
        guard minimumGB > 0, let availableBytes else { return nil }
        let minimum = UInt64(minimumGB) * bytesPerGB
        guard availableBytes < minimum else { return nil }
        return Refusal(availableBytes: availableBytes, minimumBytes: minimum)
    }

    /// What the leader reads. `hostName` is nil for a worker on this Mac.
    static func message(agentName: String, hostName: String?, refusal: Refusal) -> String {
        let place = hostName.map { "on \($0)" } ?? "on this Mac"
        let reclaim = hostName == nil
            ? "Reclaim build caches in Settings › Worktrees or with `tm-agent gc sweep --category build_caches --deep --apply`"
            : "Reclaim build caches on that host with `tm-agent gc sweep --category build_caches --deep --apply`"
        return "Not delegated to '\(agentName)': the disk it works \(place) has "
            + "\(DiskSpace.capacity(refusal.availableBytes)) free, under the "
            + "\(DiskSpace.capacity(refusal.minimumBytes)) minimum. \(reclaim), "
            + "or do the work in the leader. The minimum is set in Settings › Worktrees."
    }
}
