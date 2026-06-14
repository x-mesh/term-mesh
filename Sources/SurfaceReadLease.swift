import Foundation
import Bonsplit

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
