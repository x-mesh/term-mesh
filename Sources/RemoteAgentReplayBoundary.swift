import Foundation

/// Where a rebuilt peer agent pane's replay stops repeating what the retired
/// pane already consumed. Both seqs are host-absolute (`PtyChunk.seq` space).
enum RemoteAgentReplayBoundary {
    /// The daemon's largest replay ring (`REPLAY_CAPACITY_MAX_BYTES` in
    /// `daemon/term-meshd/src/peer/surface.rs`). No replay can repeat more.
    static let maxReplayBytes: UInt64 = 64 * 1024 * 1024

    /// Bytes at the start of the new attach that the retired consumer was
    /// already handed. Nil when the difference cannot be a replay: the new
    /// attach starts after the delivered seq (a gap), or the host's seq space
    /// restarted. Both read as a wrapped difference larger than any ring.
    nonisolated static func historyBytes(
        deliveredHostSeq: UInt64,
        newInitialSeq: UInt64,
        maxBytes: UInt64 = maxReplayBytes
    ) -> UInt64? {
        let history = deliveredHostSeq &- newInitialSeq
        return history <= maxBytes ? history : nil
    }
}
