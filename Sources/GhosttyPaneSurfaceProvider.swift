// Phase C-3c.3.3b: bridges the app's live Ghostty terminal panes into the
// PeerServer's PeerSurfaceProvider abstraction.
//
// Surface enumeration: TabManager → Workspace.panels → TerminalPanel.surface
// (TerminalSurface) → ghostty_surface_t.
//
// Input forwarding: ghostty_surface_text() on MainActor.
// Output tapping:   ghostty_surface_set_pty_data_callback() registers a C
//                   callback that yields raw PTY bytes into an AsyncStream.
//                   The callback is invoked on Ghostty's IO reader thread
//                   under renderer_state.mutex, so it must be non-blocking.
//
// Memory contract:
//   • attach() retains a PtyTapContext (strong ref keeps TerminalSurface alive)
//   • detach() clears the C callback then releases the context
//   • If the surface is freed before detach: TerminalSurface.deinit clears the
//     C callback and then ghostty_surface_free proceeds safely; the context is
//     released by the detach closure when the PeerServer eventually calls it.

#if DEBUG
import AppKit
import PeerProto

// MARK: - C callback (top-level; @convention(c) cannot capture)

private func ptyTapCallback(
    userdata: UnsafeMutableRawPointer?,
    data: UnsafePointer<UInt8>?,
    len: UInt
) {
    guard let userdata, let data, len > 0 else { return }
    let ctx = Unmanaged<PtyTapContext>.fromOpaque(userdata).takeUnretainedValue()
    ctx.continuation.yield(Data(bytes: data, count: Int(len)))
}

// MARK: - PtyTapContext

/// Bridges the Ghostty C callback to an AsyncStream.
/// Holds a strong reference to the TerminalSurface so the surface cannot
/// be freed while a peer client is actively attached.
final class PtyTapContext: @unchecked Sendable {
    let continuation: AsyncStream<Data>.Continuation
    // Strong reference prevents TerminalSurface.deinit from running while attached.
    let surfaceRef: TerminalSurface

    init(continuation: AsyncStream<Data>.Continuation, surfaceRef: TerminalSurface) {
        self.continuation = continuation
        self.surfaceRef = surfaceRef
    }
}

// MARK: - GhosttyPaneSurfaceProvider

/// PeerSurfaceProvider backed by the app's live terminal panes.
/// Conformance to PeerSurfaceProvider (which requires Sendable) is valid
/// because @MainActor isolation makes the class's state consistent.
@MainActor
final class GhosttyPaneSurfaceProvider: PeerSurfaceProvider {

    // MARK: PeerSurfaceProvider

    func listSurfaces() async -> [Termmesh_Peer_V1_SurfaceInfo] {
        await MainActor.run { collectSurfaces() }
    }

    func attach(
        surfaceID: Data,
        clientCols: UInt32,
        clientRows: UInt32
    ) async -> PeerSurfaceAttachment? {
        guard let (sfcPtr, ts) = await MainActor.run(body: { findSurface(id: surfaceID) })
        else { return nil }

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let ctx = PtyTapContext(continuation: continuation, surfaceRef: ts)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        // Register the C tap under renderer_state.mutex in Ghostty.
        ghostty_surface_set_pty_data_callback(sfcPtr, ptyTapCallback, ctxPtr)

        // Capture weak reference to TerminalSurface for input/resize closures;
        // the strong ref lives in PtyTapContext for the lifetime of the attach.
        let weakTS = WeakRef(ts)

        let input: @Sendable (Data) async -> Void = { [weakTS] bytes in
            await MainActor.run {
                guard let ptr = weakTS.value?.surface else { return }
                bytes.withUnsafeBytes { buf in
                    guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self)
                    else { return }
                    ghostty_surface_text(ptr, base, UInt(buf.count))
                }
            }
        }

        let detach: @Sendable () async -> Void = { [weakTS] in
            await MainActor.run {
                if let ptr = weakTS.value?.surface {
                    ghostty_surface_clear_pty_data_callback(ptr)
                }
            }
            continuation.finish()
            // Release the retain from passRetained above.
            Unmanaged<PtyTapContext>.fromOpaque(ctxPtr).release()
        }

        let sz = ghostty_surface_size(sfcPtr)
        let meta: PeerWorkspaceMeta? = nil

        return PeerSurfaceAttachment(
            byteStream: stream,
            input: input,
            resize: { [weakTS] cols, rows in
                await MainActor.run {
                    guard let ptr = weakTS.value?.surface else { return }
                    // ghostty_surface_set_size takes pixel dimensions.
                    // Use current cell size to convert cols×rows → pixels.
                    let curSz = ghostty_surface_size(ptr)
                    if curSz.cell_width_px > 0 && curSz.cell_height_px > 0 {
                        let w = cols * UInt32(curSz.cell_width_px)
                        let h = rows * UInt32(curSz.cell_height_px)
                        ghostty_surface_set_size(ptr, w, h)
                    }
                }
            },
            workspaceMeta: meta,
            detach: detach
        )
    }

    // MARK: - Private helpers

    private func collectSurfaces() -> [Termmesh_Peer_V1_SurfaceInfo] {
        guard let tabManager = AppDelegate.shared?.tabManager else { return [] }
        var result: [Termmesh_Peer_V1_SurfaceInfo] = []
        for workspace in tabManager.tabs {
            for (_, panel) in workspace.panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                let ts = terminal.surface
                guard let sfcPtr = ts.surface else { continue }
                var info = Termmesh_Peer_V1_SurfaceInfo()
                info.surfaceID = surfaceIDBytes(ts.id)
                info.title = workspace.panelTitles[terminal.id] ?? "Terminal"
                info.surfaceType = "terminal"
                info.attachable = true
                let sz = ghostty_surface_size(sfcPtr)
                info.cols = UInt32(sz.columns)
                info.rows = UInt32(sz.rows)
                if let cwd = workspace.panelDirectories[terminal.id] {
                    info.cwd = cwd
                }
                result.append(info)
            }
        }
        return result
    }

    private func findSurface(id: Data) -> (ghostty_surface_t, TerminalSurface)? {
        guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
        for workspace in tabManager.tabs {
            for (_, panel) in workspace.panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                let ts = terminal.surface
                guard surfaceIDBytes(ts.id) == id else { continue }
                guard let ptr = ts.surface else { continue }
                return (ptr, ts)
            }
        }
        return nil
    }
}

// MARK: - Helpers

private func surfaceIDBytes(_ id: UUID) -> Data {
    withUnsafeBytes(of: id.uuid) { Data($0) }
}

private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
#endif
