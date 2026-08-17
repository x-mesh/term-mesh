import Foundation
import Bonsplit

#if DEBUG
struct SurfaceFreeTelemetrySnapshot {
    let startedCount: Int
    let completedCount: Int
    let lastDurationMs: Double?
    /// Longest free seen for this surface.
    ///
    /// One `TerminalSurface` id can outlive more than one ghostty surface: the
    /// explicit release nils the stored pointer, and a surface realized again
    /// afterwards is freed a second time by `deinit`. Those are different
    /// pointers under one id, not a double free — but the second free is fast,
    /// so it can overwrite `lastDurationMs` before a reader sees the slow one.
    /// A test asserting on how long a resistant teardown took should use this.
    let maxDurationMs: Double?
}

/// DEBUG-only, lock-protected timing for the synchronous `ghostty_surface_free`
/// window, so a test can observe that window instead of guessing when it opens.
///
/// `surface.close` does not perform the free. It schedules it on the MainActor
/// and returns in about a millisecond, so a fixed sleep before probing is a
/// guess: probe too early and the probe records a short, meaningless value while
/// still satisfying an upper bound, and the assertion passes having measured
/// nothing.
///
/// Readers must never hop to the MainActor. During the free that thread sits in
/// `pthread_join` waiting on Ghostty's renderer and IO threads, so a query
/// isolated to the MainActor would block for exactly as long as the window it is
/// trying to observe — the measurement swallowed by the measured.
///
/// Unlike this project's other test-only counters (`GhosttySurfaceScrollView`'s
/// flash and draw counts, which are MainActor-only), these are written by the
/// MainActor and read from a socket connection thread, so every access is
/// lock-guarded.
final class SurfaceFreeTelemetry: @unchecked Sendable {
    static let shared = SurfaceFreeTelemetry()

    /// Records outlive their surface on purpose — the interesting read happens
    /// after the surface is gone — but they are capped rather than unbounded,
    /// because one DEBUG E2E session opens and closes panes continuously and no
    /// test reads a surface it closed long ago.
    private static let retainedSurfaceLimit = 256

    private struct Record {
        var startedCount = 0
        var completedCount = 0
        var startedAt: TimeInterval?
        var lastDurationMs: Double?
        var maxDurationMs: Double?
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]
    private var insertionOrder: [UUID] = []

    func recordStarted(surfaceId: UUID) {
        lock.lock()
        if records[surfaceId] == nil {
            insertionOrder.append(surfaceId)
            if insertionOrder.count > Self.retainedSurfaceLimit {
                records.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        var record = records[surfaceId, default: Record()]
        record.startedCount += 1
        record.startedAt = ProcessInfo.processInfo.systemUptime
        records[surfaceId] = record
        lock.unlock()
    }

    func recordCompleted(surfaceId: UUID) {
        // Read the clock before contending for the lock, so lock contention
        // cannot inflate the duration this exists to measure.
        let completedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        var record = records[surfaceId, default: Record()]
        record.completedCount += 1
        if let startedAt = record.startedAt {
            let elapsed = (completedAt - startedAt) * 1_000.0
            record.lastDurationMs = elapsed
            record.maxDurationMs = max(record.maxDurationMs ?? 0, elapsed)
        }
        records[surfaceId] = record
        lock.unlock()
    }

    func snapshot(surfaceId: UUID) -> SurfaceFreeTelemetrySnapshot {
        lock.lock()
        let record = records[surfaceId, default: Record()]
        lock.unlock()
        return SurfaceFreeTelemetrySnapshot(
            startedCount: record.startedCount,
            completedCount: record.completedCount,
            lastDurationMs: record.lastDurationMs,
            maxDurationMs: record.maxDurationMs
        )
    }
}
#endif

// MARK: - SurfaceFreeCoordinator

/// Coordinates deferred ghostty_surface_free with active read leases.
/// Created once per TerminalSurface; outlives the object when leases are held.
///
/// All methods must be called on the MainActor (enforced by callers).
/// Not marked @MainActor on the class itself so the property initializer in
/// the non-isolated TerminalSurface compiles without a concurrency error.
final class SurfaceFreeCoordinator {
    private var activeLeaseCount: Int = 0
    private var pendingFreeAction: (() -> Void)?

    /// Called by TerminalSurface.beginReadLease() before handing a lease out.
    @MainActor func beginLease() {
        activeLeaseCount += 1
    }

    /// Called by SurfaceReadLease.release() (dispatched onto MainActor).
    @MainActor func endLease() {
        activeLeaseCount -= 1
        #if DEBUG
        // Leak instrumentation: a deferred free becoming unblocked. Pairs with the
        // `surface.free.deferred` line below — a `deferred` with no subsequent
        // `lease_drained`+`surface.free.perform` is a permanently stuck surface
        // (no sweeper exists here), i.e. the IOSurface/GPU leak signature.
        if activeLeaseCount == 0, pendingFreeAction != nil {
            dlog("surface.free.lease_drained leases=0 — performing deferred free")
        }
        #endif
        triggerIfReady()
    }

    /// Schedule the free action to run once all leases have been released.
    /// If no leases are currently active, the action runs immediately.
    @MainActor func scheduleClose(_ action: @escaping () -> Void) {
        guard pendingFreeAction == nil else { return }  // guard against double-close
        pendingFreeAction = action
        #if DEBUG
        // Leak instrumentation: close requested while reader leases are still held.
        // The free (ghostty_surface_free) cannot run yet; it is deferred until all
        // leases release. If a lease never releases, this surface leaks forever.
        if activeLeaseCount > 0 {
            dlog("surface.free.deferred leases=\(activeLeaseCount)")
        }
        #endif
        triggerIfReady()
    }

    @MainActor private func triggerIfReady() {
        guard activeLeaseCount == 0, let action = pendingFreeAction else { return }
        pendingFreeAction = nil
        action()
    }
}

// MARK: - SurfaceReadLease

/// Scoped read-access token for a live ghostty terminal surface pointer.
///
/// While a lease is alive, ghostty_surface_free() is guaranteed not to run
/// for the associated surface — the free is deferred until all leases release.
///
/// Obtain via TerminalSurface.beginReadLease() on the MainActor.
/// Release explicitly with release() when done, or let deinit call it as a
/// safety net. release() is idempotent and thread-safe.
final class SurfaceReadLease: @unchecked Sendable {
    /// Raw surface pointer — valid for the duration of this lease.
    let surface: ghostty_surface_t
    /// Generation counter captured at lease creation. Use to detect stale leases
    /// when the surface is detached and reattached between async hops.
    let generation: UInt64

    private let coordinator: SurfaceFreeCoordinator
    private let lock = NSLock()
    private var released = false

    init(
        surface: ghostty_surface_t,
        generation: UInt64,
        coordinator: SurfaceFreeCoordinator
    ) {
        self.surface = surface
        self.generation = generation
        self.coordinator = coordinator
    }

    /// Signal that the caller is done using `surface`.
    /// Safe to call from any thread; may be called multiple times (idempotent).
    func release() {
        lock.lock()
        let wasReleased = released
        released = true
        lock.unlock()
        guard !wasReleased else { return }
        let c = coordinator
        Task { @MainActor in c.endLease() }
    }

    deinit { release() }
}
