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

import AppKit
import Bonsplit
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
        // Background panes have a lazy `ghostty_surface_t` — newly opened
        // splits / non-active tabs may not have one yet. Kick lazy init
        // for any unready pane and wait briefly so the next collect
        // picks them up. Without this the latest split is silently
        // dropped from the picker.
        await MainActor.run { kickLazySurfaceStarts() }
        for _ in 0..<10 {
            if await MainActor.run(body: { allSurfacesReady() }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms × 10 = ≤300 ms
        }
        return await MainActor.run { collectSurfaces() }
    }

    func listWorkspaces() async -> [Termmesh_Peer_V1_Workspace] {
        await MainActor.run { kickLazySurfaceStarts() }
        for _ in 0..<10 {
            if await MainActor.run(body: { allSurfacesReady() }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await MainActor.run { collectWorkspaces() }
    }

    func handleWorkspaceControl(_ control: Termmesh_Peer_V1_WorkspaceControl) async {
        await MainActor.run { applyWorkspaceControl(control) }
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

        // Send a snapshot of the current viewport so the relay window
        // shows existing content immediately instead of starting blank.
        // Yielded before the callback is registered so it's guaranteed
        // to land before any new PTY bytes. ANSI styling is lost (text
        // only); fullscreen TUIs (vim, less, htop) won't redraw without
        // SIGWINCH and require manual refresh.
        if let snapshot = readPaneSnapshot(sfcPtr) {
            continuation.yield(snapshot)
        }

        // Register the C tap under renderer_state.mutex in Ghostty.
        ghostty_surface_set_pty_data_callback(sfcPtr, ptyTapCallback, ctxPtr)

        // Light up the peer-attached ring on the host pane and bump
        // the per-surface ref count so concurrent attaches all share
        // a single visible ring.
        Self.incrementPeerAttach(for: ts)

        // Capture weak reference to TerminalSurface for input/resize closures;
        // the strong ref lives in PtyTapContext for the lifetime of the attach.
        let weakTS = WeakRef(ts)

        let input: @Sendable (Data) async -> Void = { [weakTS] bytes in
            await MainActor.run {
                guard let ptr = weakTS.value?.surface else { return }
                sendPeerInputBytes(ptr, bytes: bytes)
            }
        }

        let detach: @Sendable () async -> Void = { [weakTS] in
            await MainActor.run {
                if let ptr = weakTS.value?.surface {
                    ghostty_surface_clear_pty_data_callback(ptr)
                }
                if let ts = weakTS.value {
                    GhosttyPaneSurfaceProvider.decrementPeerAttach(for: ts)
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

    // MARK: - Workspace control dispatch

    private func applyWorkspaceControl(_ control: Termmesh_Peer_V1_WorkspaceControl) {
        switch control.kind {
        case .splitPane(let req):
            performSplit(paneIDBytes: req.paneID, orientationString: req.orientation)
        case .closePane(let req):
            performClose(paneIDBytes: req.paneID)
        case .focusPane(let req):
            performFocus(paneIDBytes: req.paneID)
        case .setDivider(let req):
            performSetDivider(splitIDBytes: req.splitID, ratio: req.ratio)
        case .newTab(let req):
            performNewTab(paneIDBytes: req.paneID)
        case .none:
            break
        }
    }

    private func performNewTab(paneIDBytes: Data) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: panelUUID),
              let tabID = workspace.surfaceIdFromPanelId(panelUUID)
        else { return }
        let targetPaneId = workspace.bonsplitController.allPaneIds.first { paneId in
            workspace.bonsplitController.tabs(inPane: paneId).contains { $0.id == tabID }
        }
        guard let targetPaneId else { return }
        _ = workspace.newTerminalSurface(inPane: targetPaneId, focus: true)
    }

    private func performSetDivider(splitIDBytes: Data, ratio: Double) {
        guard let splitUUID = uuidFromSurfaceID(splitIDBytes),
              let tabManager = AppDelegate.shared?.tabManager
        else { return }
        let clamped = CGFloat(max(0.05, min(0.95, ratio)))
        for workspace in tabManager.tabs {
            if workspace.bonsplitController.findSplit(splitUUID) {
                workspace.bonsplitController.setDividerPosition(
                    clamped,
                    forSplit: splitUUID,
                    fromExternal: false
                )
                return
            }
        }
    }

    private func performFocus(paneIDBytes: Data) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: panelUUID),
              let tabID = workspace.surfaceIdFromPanelId(panelUUID)
        else { return }
        // Drive bonsplit directly. The full `Workspace.focusPanel`
        // path also calls `moveFocus` which ends up running
        // `window.makeKeyAndOrderFront` on the host's main term-mesh
        // window — that yanks the user's keyboard focus out of the
        // peer relay window every time they click a pane in it.
        let targetPaneId = workspace.bonsplitController.allPaneIds.first { paneId in
            workspace.bonsplitController.tabs(inPane: paneId).contains { $0.id == tabID }
        }
        guard let targetPaneId else { return }
        workspace.bonsplitController.focusPane(targetPaneId)
        workspace.bonsplitController.selectTab(tabID)
    }

    private func performSplit(paneIDBytes: Data, orientationString: String) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: panelUUID)
        else { return }
        let orientation: SplitOrientation = (orientationString == "vertical") ? .vertical : .horizontal
        _ = workspace.newTerminalSplit(from: panelUUID, orientation: orientation)
    }

    private func performClose(paneIDBytes: Data) {
        guard let panelUUID = uuidFromSurfaceID(paneIDBytes),
              let workspace = workspaceContaining(panelUUID: panelUUID),
              let panel = workspace.panels[panelUUID]
        else { return }
        // Use bonsplit's pane-id derivation: find the pane that holds
        // the tab whose ID matches this terminal surface, then close it.
        if let tabID = workspace.surfaceIdFromPanelId(panelUUID) {
            for paneId in workspace.bonsplitController.allPaneIds {
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                if tabs.contains(where: { $0.id == tabID }) {
                    _ = workspace.bonsplitController.closeTab(tabID, inPane: paneId)
                    return
                }
            }
        }
        _ = panel  // silence unused
    }

    private func uuidFromSurfaceID(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let tuple = data.withUnsafeBytes { raw -> uuid_t in
            raw.load(as: uuid_t.self)
        }
        return UUID(uuid: tuple)
    }

    private func workspaceContaining(panelUUID: UUID) -> Workspace? {
        guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
        for workspace in tabManager.tabs {
            if workspace.panels[panelUUID] != nil {
                return workspace
            }
        }
        return nil
    }

    // MARK: - Peer attach indicator

    /// Per-surface attach counter. Lives on the @MainActor-isolated
    /// type so reads/writes serialize with the rest of provider state.
    private static var peerAttachCounts: [UUID: Int] = [:]

    static func incrementPeerAttach(for ts: TerminalSurface) {
        let prev = peerAttachCounts[ts.id] ?? 0
        peerAttachCounts[ts.id] = prev + 1
        if prev == 0 {
            ts.hostedView.setPeerRing(visible: true)
        }
    }

    static func decrementPeerAttach(for ts: TerminalSurface) {
        let prev = peerAttachCounts[ts.id] ?? 0
        let next = max(0, prev - 1)
        if next == 0 {
            peerAttachCounts.removeValue(forKey: ts.id)
            ts.hostedView.setPeerRing(visible: false)
        } else {
            peerAttachCounts[ts.id] = next
        }
    }

    // MARK: - Private helpers

    /// Wake up any pane whose `ghostty_surface_t` hasn't been created
    /// yet (newly opened splits, background tabs). Non-blocking — caller
    /// polls `allSurfacesReady` to know when init has settled.
    private func kickLazySurfaceStarts() {
        guard let tabManager = AppDelegate.shared?.tabManager else { return }
        for workspace in tabManager.tabs {
            for (_, panel) in workspace.panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                let ts = terminal.surface
                if ts.surface == nil {
                    ts.requestBackgroundSurfaceStartIfNeeded()
                }
            }
        }
    }

    /// True when every terminal pane has a non-nil `ghostty_surface_t`.
    private func allSurfacesReady() -> Bool {
        guard let tabManager = AppDelegate.shared?.tabManager else { return true }
        for workspace in tabManager.tabs {
            for (_, panel) in workspace.panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                if terminal.surface.surface == nil { return false }
            }
        }
        return true
    }

    private func collectWorkspaces() -> [Termmesh_Peer_V1_Workspace] {
        guard let tabManager = AppDelegate.shared?.tabManager else { return [] }
        var result: [Termmesh_Peer_V1_Workspace] = []
        for workspace in tabManager.tabs {
            let tree = workspace.bonsplitController.treeSnapshot()
            guard let layout = translateBonsplitNode(tree, workspace: workspace) else {
                continue
            }
            var ws = Termmesh_Peer_V1_Workspace()
            ws.workspaceID = withUnsafeBytes(of: workspace.id.uuid) { Data($0) }
            ws.title = workspace.customTitle ?? workspace.title
            ws.layout = layout
            result.append(ws)
        }
        return result
    }

    /// Walk a bonsplit `ExternalTreeNode` and produce the corresponding
    /// `WorkspaceLayout` proto. Pane leaves are dereferenced via
    /// `workspace.surfaceIdToPanelId` to find the underlying
    /// TerminalSurface ID — that's the value clients use for
    /// AttachSurface. Non-terminal panes (browsers, panes whose
    /// surface hasn't materialised yet) are dropped; if both children
    /// of a split drop, the split itself is folded out.
    private func translateBonsplitNode(
        _ node: ExternalTreeNode,
        workspace: Workspace
    ) -> Termmesh_Peer_V1_WorkspaceLayout? {
        switch node {
        case .pane(let pane):
            guard let selectedTabIDStr = pane.selectedTabId ?? pane.tabs.first?.id,
                  let tabUUID = UUID(uuidString: selectedTabIDStr),
                  let panelUUID = workspace.surfaceIdToPanelId[TabID(uuid: tabUUID)],
                  let terminal = workspace.panels[panelUUID] as? TerminalPanel,
                  let sfcPtr = terminal.surface.surface
            else { return nil }
            let ts = terminal.surface
            var paneMsg = Termmesh_Peer_V1_WorkspacePane()
            paneMsg.surfaceID = surfaceIDBytes(ts.id)
            paneMsg.title = workspace.panelTitles[terminal.id] ?? "Terminal"
            let sz = ghostty_surface_size(sfcPtr)
            paneMsg.cols = UInt32(sz.columns)
            paneMsg.rows = UInt32(sz.rows)
            if let cwd = workspace.panelDirectories[terminal.id] {
                paneMsg.cwd = cwd
            }
            var layout = Termmesh_Peer_V1_WorkspaceLayout()
            layout.pane = paneMsg
            return layout

        case .split(let split):
            let firstChild = translateBonsplitNode(split.first, workspace: workspace)
            let secondChild = translateBonsplitNode(split.second, workspace: workspace)
            // If one side has nothing attachable, fold the split out
            // and surface only the populated child.
            switch (firstChild, secondChild) {
            case (nil, nil):
                return nil
            case (let f?, nil):
                return f
            case (nil, let s?):
                return s
            case (let f?, let s?):
                var splitMsg = Termmesh_Peer_V1_WorkspaceSplit()
                splitMsg.orientation = split.orientation
                splitMsg.dividerPosition = split.dividerPosition
                splitMsg.first = f
                splitMsg.second = s
                if let splitUUID = UUID(uuidString: split.id) {
                    splitMsg.splitID = withUnsafeBytes(of: splitUUID.uuid) { Data($0) }
                }
                var layout = Termmesh_Peer_V1_WorkspaceLayout()
                layout.split = splitMsg
                return layout
            }
        }
    }

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

/// Route peer Input bytes into Ghostty as key events.
///
/// All bytes flow through `ghostty_surface_key()`; we deliberately avoid
/// `ghostty_surface_text()` because that path wraps content in bracketed
/// paste markers which (a) breaks Enter / Tab / Ctrl-C semantics in
/// readline-style shells and (b) eats some control bytes before they
/// reach the PTY. Mirroring `GhosttyTerminalView.sendSocketStyleText`:
///
/// - Enter (CR/LF), Tab, Backspace, Escape       → key event with keycode
/// - 3-byte CSI arrow sequences (`\x1b[A/B/C/D`) → arrow key event
/// - Ctrl-letter control bytes (0x01-0x1A)       → key event + Ctrl mod
/// - Anything else                                → key event (keycode=0)
///   with the Unicode scalar as text. Multi-byte UTF-8 sequences are
///   grouped into a single scalar before dispatch.
///
/// LF→Return mapping is needed because the relay binary's stdin is a PTY
/// slave with default ICRNL, so Ghostty writes CR but the relay reads
/// LF before forwarding over the peer socket.
@MainActor
private func sendPeerInputBytes(_ surface: ghostty_surface_t, bytes: Data) {
    let arr = Array(bytes)
    var i = 0
    while i < arr.count {
        let byte = arr[i]

        // 3-byte CSI arrow sequence comes in one frame for most TUIs.
        if byte == 0x1b, i + 2 < arr.count, arr[i + 1] == 0x5b /* '[' */,
           let arrowKeycode = peerArrowKeycode(arr[i + 2]) {
            sendPeerKeyEvent(surface, keycode: arrowKeycode, text: nil)
            i += 3
            continue
        }

        if let mapping = peerSingleByteKeyMapping(byte) {
            sendPeerKeyEvent(surface, keycode: mapping.keycode, text: mapping.text)
            i += 1
            continue
        }

        if let kc = peerCtrlLetterKeycode(byte) {
            sendPeerCtrlLetterKey(surface, keycode: kc, byte: byte)
            i += 1
            continue
        }

        // Printable / UTF-8 path: group continuation bytes for one scalar.
        let scalarEnd = min(i + peerUtf8Len(byte), arr.count)
        let chunkBytes = Array(arr[i..<scalarEnd])
        if let str = String(bytes: chunkBytes, encoding: .utf8) {
            for scalar in str.unicodeScalars {
                sendPeerKeyEvent(surface, keycode: 0, text: String(scalar))
            }
            i = scalarEnd
        } else {
            // Lone byte fallback when UTF-8 decoding fails (rare for
            // typed input).
            sendPeerKeyEvent(surface, keycode: 0, text: String(UnicodeScalar(byte)))
            i += 1
        }
    }
}

/// Special single bytes that map to a named macOS keycode.
private func peerSingleByteKeyMapping(_ byte: UInt8) -> (keycode: UInt32, text: String)? {
    switch byte {
    case 0x0d, 0x0a: return (36, "\r")          // kVK_Return
    case 0x09:        return (0x30, "\t")        // kVK_Tab
    case 0x7f, 0x08:  return (0x33, "\u{7f}")    // kVK_Delete (Backspace)
    case 0x1b:        return (0x35, "\u{1b}")    // kVK_Escape
    default:          return nil
    }
}

/// Map a Ctrl+letter control byte (0x01-0x1A, excluding bytes already
/// claimed by `peerSingleByteKeyMapping`) to its `kVK_ANSI_*` keycode.
private func peerCtrlLetterKeycode(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 0x01: return 0x00 // Ctrl-A → kVK_ANSI_A
    case 0x02: return 0x0B // Ctrl-B → kVK_ANSI_B
    case 0x03: return 0x08 // Ctrl-C → kVK_ANSI_C
    case 0x04: return 0x02 // Ctrl-D → kVK_ANSI_D
    case 0x05: return 0x0E // Ctrl-E → kVK_ANSI_E
    case 0x06: return 0x03 // Ctrl-F → kVK_ANSI_F
    case 0x07: return 0x05 // Ctrl-G → kVK_ANSI_G
    // 0x08 BS, 0x09 Tab, 0x0a LF — handled above
    case 0x0B: return 0x28 // Ctrl-K → kVK_ANSI_K
    case 0x0C: return 0x25 // Ctrl-L → kVK_ANSI_L
    // 0x0d CR — handled above
    case 0x0E: return 0x2D // Ctrl-N → kVK_ANSI_N
    case 0x0F: return 0x1F // Ctrl-O → kVK_ANSI_O
    case 0x10: return 0x23 // Ctrl-P → kVK_ANSI_P
    case 0x11: return 0x0C // Ctrl-Q → kVK_ANSI_Q
    case 0x12: return 0x0F // Ctrl-R → kVK_ANSI_R
    case 0x13: return 0x01 // Ctrl-S → kVK_ANSI_S
    case 0x14: return 0x11 // Ctrl-T → kVK_ANSI_T
    case 0x15: return 0x20 // Ctrl-U → kVK_ANSI_U
    case 0x16: return 0x09 // Ctrl-V → kVK_ANSI_V
    case 0x17: return 0x0D // Ctrl-W → kVK_ANSI_W
    case 0x18: return 0x07 // Ctrl-X → kVK_ANSI_X
    case 0x19: return 0x10 // Ctrl-Y → kVK_ANSI_Y
    case 0x1A: return 0x06 // Ctrl-Z → kVK_ANSI_Z
    // 0x1b Esc — handled above
    default:   return nil
    }
}

/// Map the third byte of a `\x1b[?` CSI sequence to its arrow keycode.
private func peerArrowKeycode(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 0x41: return 0x7e // 'A' → kVK_UpArrow
    case 0x42: return 0x7d // 'B' → kVK_DownArrow
    case 0x43: return 0x7c // 'C' → kVK_RightArrow
    case 0x44: return 0x7b // 'D' → kVK_LeftArrow
    default:   return nil
    }
}

/// Number of bytes in the UTF-8 sequence whose lead byte is `byte`.
/// Returns 1 for ASCII and for stray continuation bytes.
private func peerUtf8Len(_ byte: UInt8) -> Int {
    if byte < 0x80 { return 1 }
    if byte < 0xC0 { return 1 }
    if byte < 0xE0 { return 2 }
    if byte < 0xF0 { return 3 }
    return 4
}

@MainActor
private func sendPeerKeyEvent(_ surface: ghostty_surface_t, keycode: UInt32, text: String?) {
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = GHOSTTY_ACTION_PRESS
    keyEvent.keycode = keycode
    keyEvent.mods = GHOSTTY_MODS_NONE
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = 0
    keyEvent.composing = false
    if let text {
        text.withCString { ptr in
            keyEvent.text = ptr
            _ = ghostty_surface_key(surface, keyEvent)
        }
    } else {
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
    }
    keyEvent.action = GHOSTTY_ACTION_RELEASE
    keyEvent.text = nil
    _ = ghostty_surface_key(surface, keyEvent)
}

@MainActor
private func sendPeerCtrlLetterKey(_ surface: ghostty_surface_t, keycode: UInt32, byte: UInt8) {
    // Don't send text for Ctrl+key combos — keycode + mods +
    // unshifted_codepoint are enough for Ghostty's KeyEncoder. Adding
    // the raw control byte as text triggers Kitty-protocol double
    // encoding that leaks CSI-u sequences (e.g. "9;5u") as visible
    // text. Mirrors the de5df7d fix in GhosttyTerminalView's Ctrl
    // fast path.
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = GHOSTTY_ACTION_PRESS
    keyEvent.keycode = keycode
    keyEvent.mods = GHOSTTY_MODS_CTRL
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = UInt32(byte) + 0x60 // 0x03 → 'c'
    keyEvent.composing = false
    keyEvent.text = nil
    _ = ghostty_surface_key(surface, keyEvent)

    keyEvent.action = GHOSTTY_ACTION_RELEASE
    _ = ghostty_surface_key(surface, keyEvent)
}

/// Read the current viewport text via ghostty_surface_read_text and
/// wrap it in an ANSI clear+home prefix so the attaching client sees
/// the host's current screen instead of a blank canvas.
@MainActor
private func readPaneSnapshot(_ surface: ghostty_surface_t) -> Data? {
    let topLeft = ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0, y: 0
    )
    let bottomRight = ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0, y: 0
    )
    let selection = ghostty_selection_s(
        top_left: topLeft,
        bottom_right: bottomRight,
        rectangle: true
    )
    var out = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
    defer { ghostty_surface_free_text(surface, &out) }
    guard let ptr = out.text, out.text_len > 0 else { return nil }

    let raw = Data(bytes: ptr, count: Int(out.text_len))
    // Convert bare LFs to CR+LF so each line lands on column 0 in the
    // remote terminal emulator. Already-CRLF input is left untouched.
    var body = Data()
    body.reserveCapacity(raw.count + 16)
    var prev: UInt8 = 0
    for b in raw {
        if b == 0x0a && prev != 0x0d {
            body.append(0x0d)
        }
        body.append(b)
        prev = b
    }

    var snapshot = Data()
    snapshot.append(contentsOf: [0x1b, 0x5b, 0x32, 0x4a]) // ESC [ 2 J — clear screen
    snapshot.append(contentsOf: [0x1b, 0x5b, 0x48])       // ESC [ H   — cursor home
    snapshot.append(body)
    return snapshot
}

private func surfaceIDBytes(_ id: UUID) -> Data {
    withUnsafeBytes(of: id.uuid) { Data($0) }
}

private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
