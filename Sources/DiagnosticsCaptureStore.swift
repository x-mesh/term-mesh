import Foundation

/// A diagnostics snapshot frozen at the moment something looked wrong.
struct DiagnosticsCapture: Identifiable {
    let id = UUID()
    let capturedAt: Date
    /// One line naming what triggered the capture, shown in the picker.
    let reason: String
    let snapshot: DiagnosticsSnapshot
}

/// Keeps the last few captures so a report can describe the failure rather
/// than the recovery.
///
/// By the time someone opens the report window the app has usually moved on:
/// the host reconnected, the version was upgraded, the log rolled. This
/// project has already paid for that once — a reported screenshot showed
/// `term-meshd v0.195.0` while the host had been on 0.196.0 for hours, and the
/// mismatch sent the investigation down a version-upgrade path that had
/// nothing to do with the defect.
///
/// Two properties keep this honest:
///
/// - **No new probing.** Captures reuse measurements the app already made. A
///   background timer running SSH against every host would be a real cost
///   levied on every user to serve the rare one who files a report.
/// - **Nothing is sent.** A capture is held in memory and offered in the
///   report window. It leaves only if a person selects it, reads it, and
///   presses the button.
///
/// This is a snapshot of *state*, never of the screen. Pixels cannot be
/// redacted and the app does not capture them.
@MainActor
final class DiagnosticsCaptureStore: ObservableObject {
    static let shared = DiagnosticsCaptureStore()

    /// Enough to cover "it happened a few minutes ago" without letting old
    /// snapshots accumulate in memory for a session that never reports.
    static let limit = 5

    /// A host that stays unhealthy re-probes every time its editor opens.
    /// Without a floor the store would fill with near-identical snapshots and
    /// push out the older, more interesting ones.
    static let minimumInterval: TimeInterval = 60

    @Published private(set) var captures: [DiagnosticsCapture] = []

    private var lastCaptureByReasonKey: [String: Date] = [:]

    /// Freeze the current state alongside a health baseline that was just
    /// measured.
    ///
    /// The baseline is the perishable part: it is computed only while a host
    /// editor is open and discarded when that sheet closes, so it is the one
    /// piece of evidence that cannot be recovered later by opening the report
    /// window. Everything else in the snapshot is still readable at any time.
    func recordUnhealthyHost(
        sshTarget: String,
        health: PeerHostHealthBaseline,
        now: Date = Date()
    ) {
        guard health.verdict != .healthy else { return }
        let key = "health:\(sshTarget):\(health.verdict.rawValue)"
        if let last = lastCaptureByReasonKey[key], now.timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        lastCaptureByReasonKey[key] = now

        let reason = "peer host \(health.verdict.rawValue)"
        var snapshot = DiagnosticsReport
            .current(daemonStatus: nil)
            .attaching(health, toHostMatching: sshTarget)
        snapshot.capturedAt = now
        snapshot.captureReason = reason
        append(DiagnosticsCapture(capturedAt: now, reason: reason, snapshot: snapshot))
    }

    private func append(_ capture: DiagnosticsCapture) {
        captures.insert(capture, at: 0)
        if captures.count > Self.limit {
            captures.removeLast(captures.count - Self.limit)
        }
    }

    /// Test seam — captures are session state, not persisted, so a reset is
    /// all a test needs.
    func removeAll() {
        captures.removeAll()
        lastCaptureByReasonKey.removeAll()
    }
}

extension DiagnosticsSnapshot {
    /// Attach a measured baseline to the host it belongs to.
    ///
    /// Matched on the SSH target because that is the identity the probe was
    /// run against; a host with no target cannot have produced this baseline.
    /// A snapshot taken while the host list is empty keeps the baseline
    /// nowhere rather than guessing an owner for it.
    func attaching(
        _ health: PeerHostHealthBaseline,
        toHostMatching sshTarget: String
    ) -> DiagnosticsSnapshot {
        var copy = self
        copy.peerHosts = peerHosts.map { host in
            guard host.sshTarget == sshTarget else { return host }
            var updated = host
            updated.healthBaseline = health
            return updated
        }
        return copy
    }
}
