import Foundation

/// Where a rebuilt peer agent pane's replay stops repeating what the retired
/// pane already consumed. All seqs are host-absolute (`PtyChunk.seq` space).
enum RemoteAgentReplayBoundary {
    /// A fresh agent attach replays at most the ring tail the daemon sends a
    /// new consumer (`FRESH_ATTACH_REPLAY_BYTES`, whose chunks never exceed
    /// `READ_BUF_SIZE`, both 64 KiB in `daemon/term-meshd/src/peer/surface.rs`).
    static let maxReplayBytes: UInt64 = 64 * 1024

    /// Bytes at the start of the new attach that the retired consumer already
    /// applied. Nil when the two attaches cannot share one seq space: the new
    /// attach starts after the boundary (a gap), before the retired attach's
    /// own start (a fresh tail never moves backwards on a live host, so the
    /// host restarted), or further back than any fresh attach replays.
    nonisolated static func historyBytes(
        appliedHostSeq: UInt64,
        retiredInitialSeq: UInt64,
        newInitialSeq: UInt64
    ) -> UInt64? {
        guard newInitialSeq >= retiredInitialSeq,
              newInitialSeq <= appliedHostSeq
        else { return nil }
        let history = appliedHostSeq - newInitialSeq
        return history <= maxReplayBytes ? history : nil
    }
}
