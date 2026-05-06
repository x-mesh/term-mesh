# Peer Federation — Implementation Status

Last updated: 2026-05-06
Branch: `feat/peer-federation`

This document tracks the implementation progress of peer federation phases.
Design doc: `peer-federation.md` / `peer-federation-protocol.md`.

---

## Phase Map (Swift + Rust, in-app proof-of-concept)

Phase D-1 lifts the DEBUG guards: peer-federation source files compile
into Release builds and the menu items are always visible. The peer
server still does not run by default — it is opt-in via either the
status-bar menu or the `TERMMESH_PEER_SERVER_PATH` env var.

```
Phase A  — Protocol + transport library (PeerProto Swift package)           ✅ DONE
Phase B  — term-meshd Rust peer server (term-mesh-peer-relay basis)         ✅ DONE
Phase C  — In-app Swift peer client + Ghostty relay window
  C-1    — PeerSession: attach + streaming + input/resize                   ✅ DONE
  C-2α   — Debug console window renders remote PTY stream                   ✅ DONE
  C-3    — Swift peer server inside term-mesh.app
    C-3c.1   PeerSession client-side session management                     ✅ DONE
    C-3c.2α  Debug console: stream + input via PeerSession                  ✅ DONE
    C-3c.3.1 Swift peer server skeleton: listen + handshake + list          ✅ DONE
    C-3c.3.2 Swift peer server: attach, streaming, Input routing            ✅ DONE
    C-3c.3.3 term-mesh.app runs peer server (GhosttyPaneSurfaceProvider)   ✅ DONE
  C-4    — Ghostty relay window (real Ghostty surface shows remote PTY)     ✅ DONE
  C-4.1  — Surface picker dialog (multi-pane hosts)                         ✅ DONE
  C-4.2  — Peer-attached ring on host pane (teal overlay, ref-counted)      ✅ DONE
Phase W  — Layout-preserving workspace relay
  W-1    — Proto: WorkspaceLayout / Workspace / ListWorkspaces              ✅ DONE
  W-2    — Host: serialize bonsplit treeSnapshot → WorkspaceLayout          ✅ DONE
  W-3    — Picker: choose workspace                                         ✅ DONE
  W-4    — PeerRelayWorkspaceWindowController (NSSplitView reconstruction)  ✅ DONE
Phase W' — Live workspace layout sync                                       ✅ DONE
Phase D  — Production integration
  D-1    — Drop #if DEBUG guards, opt-in env var                            ✅ DONE
  D-2    — Main UI integration (preferences pane, sidebar)                  ⬜ TODO
  D-3    — Bonjour mDNS discovery                                           ⬜ TODO
  D-4    — SSH transport                                                    ⬜ TODO
```

---

## Phase C-4 — Ghostty Relay Window

**Goal:** "Connect to Peer via Ghostty Relay… (debug)" menu opens a real Ghostty terminal window rendering the remote peer's PTY stream.

**Data flow:**
```
[remote host PTY]
     ↓ PeerSession PtyData
[PeerRelaySession]  (Swift)
     ↓ Unix socket, framed protocol (type=0x01/02/03/FF)
[term-mesh-peer-relay]  ← Ghostty spawns as "shell"
     ↓ stdout → Ghostty master PTY → Ghostty renders
     ↑ stdin (user keys) → socket type=0x02 → PeerSession Input
     ↑ SIGWINCH → socket type=0x03 → PeerSession Resize
```

### Key files

| File | Role |
|------|------|
| `Sources/PeerRelaySession.swift` | Socket listener, accept, bidirectional pump |
| `Sources/PeerRelayWindowController.swift` | NSWindow hosting TerminalSurface (relay binary as shell) |
| `Sources/PeerDebugMenu.swift` | Menu items + PeerDebugCoordinator (holds open window refs) |
| `Sources/PeerDebugServer.swift` | DEBUG peer server (Start/Stop via menu) |
| `Sources/GhosttyPaneSurfaceProvider.swift` | Maps live Ghostty panes to PeerSurfaceProvider |
| `daemon/term-mesh-peer-relay/src/main.rs` | Relay binary: stdout/stdin/SIGWINCH framing |

### Bugs fixed during C-4 development

1. **ARC deallocation** — `PeerRelayWindowController` was a local `let` inside a Task closure → immediately deallocated → `PeerRelaySession.deinit` removed the relay socket → relay binary couldn't connect.
   - Fix: store controller in `PeerDebugCoordinator.openRelays: [PeerRelayWindowController]`.

2. **Swift DEBUG alignment trap (UInt32)** — `UnsafeRawBufferPointer.load(fromByteOffset: 1, as: UInt32.self)` asserts 4-byte alignment in DEBUG builds. Relay frame header has length at byte offset 1 (not aligned).
   - Fix: `loadUnaligned(fromByteOffset: 1, as: UInt32.self)` in `RelaySocket.readFrame()`.

3. **Swift DEBUG alignment trap (UInt16 × 2)** — Same issue in Resize frame payload parsing (offsets 0 and 2 for cols/rows).
   - Fix: `loadUnaligned` for both reads.

4. **O_NONBLOCK inheritance** — `acceptRelay()` sets the listener socket to `O_NONBLOCK` for polling. The accepted fd inherits this flag. The first `read()` after the Resize frame returned `EAGAIN` (errno 35), which `readFull()` treated as fatal → `relayToHost` task called `disconnect()` → window closed immediately.
   - Fix: after `Darwin.accept()` returns a valid fd, reset to blocking:
     ```swift
     _ = Darwin.fcntl(fd, F_SETFL, Darwin.fcntl(fd, F_GETFL) & ~O_NONBLOCK)
     ```

5. **Bracketed-paste swallowing keystrokes** — `GhosttyPaneSurfaceProvider` initially routed all peer Input bytes through `ghostty_surface_text()`, which wraps content in `\e[200~…\e[201~`. Shells then treated CR / Tab / Ctrl-C as pasted whitespace instead of keystrokes, so commands typed in the relay window moved to the next line without executing and signals were silently dropped.
   - Fix: route every peer byte through `ghostty_surface_key()` instead. Recognize 3-byte CSI arrow sequences, named keys (Return / Tab / Backspace / Escape) and Ctrl+letter (`0x01`–`0x1A` → `kVK_ANSI_<letter>` + `GHOSTTY_MODS_CTRL` with `text=nil` and `unshifted_codepoint = byte+0x60`). Mirrors the de5df7d Kitty-protocol fix.

6. **Line-buffered relay stdin swallowed Tab / Ctrl-C / arrow keys** — without raw mode, the relay binary's stdin held single keystrokes in the kernel line buffer until Enter was pressed, so the host never saw them. Only complete `…\n` lines made it through.
   - Fix: enable `cfmakeraw` + `VMIN=1, VTIME=0` on `STDIN_FILENO` at startup; restore the original termios via an RAII guard on exit.

7. **Snapshot-on-attach** — early relay sessions started with a blank surface even though the host had a full screen of content; only new output appeared.
   - Fix: read the current viewport via `ghostty_surface_read_text` and yield an `ESC[2J ESC[H` + text snapshot into the byte stream before registering the C tap callback.

### Current status (2026-05-06)

- Relay window opens ✅
- Bidirectional pump (PtyData / KeyInput / Resize / Goodbye) ✅
- Ghostty renders host PTY output in relay surface ✅
- Enter / Tab / Backspace / Escape / arrow keys all execute on host ✅
- Ctrl-C and other Ctrl+letter combinations interrupt on host ✅
- Initial viewport snapshot on attach (no longer starts blank) ✅
- Stable streaming over multi-minute sessions (no spurious disconnect) ✅

### Test setup

The peer server is `#if DEBUG` only (in `PeerDebugServer.swift`). Either flow works:

1. Launch the app with `TERMMESH_DEBUG_PEER_SERVER_PATH=/tmp/termmesh-app-peer.sock`
   to auto-start the server, **or** click menu →
   **"Start Peer Server… (debug)"**.
2. Pick one of the three relay menu items:
   - **"Connect to Peer… (debug)"** — raw NSTextView console for the
     PtyData stream (oldest debug surface).
   - **"Connect to Peer via Ghostty Relay… (debug)"** — single Ghostty
     surface mirroring one host pane. Surface picker pops up when the
     host has multiple panes.
   - **"Connect to Peer Workspace via Ghostty Relay… (debug)"** —
     single window with the host workspace's full split layout
     reproduced via NSSplitView; one PeerRelaySession per leaf pane.
3. Active peer attachments light up a **teal ring** around the host
   pane(s); the ring is reference-counted so multiple clients on the
   same pane keep it lit until the last one detaches.

---

## Phase W — Layout-Preserving Workspace Relay

**Goal:** when a client attaches to a workspace (host tab), the local
relay window mirrors not only every pane's PTY stream but also the
host's split arrangement, so the user sees the same layout they had
on the host.

**Pieces:**

| Layer | What changed |
|-------|--------------|
| Proto | New `ListWorkspaces` / `WorkspaceList` RPC plus `Workspace` / `WorkspaceLayout` (recursive `oneof split | pane`) / `WorkspaceSplit` / `WorkspacePane` messages. |
| Host  | `GhosttyPaneSurfaceProvider.listWorkspaces()` walks `tabManager.tabs`, calls `bonsplitController.treeSnapshot()`, and translates each `ExternalTreeNode` into a `WorkspaceLayout` proto. Empty/non-attachable subtrees are folded out. |
| Client | `PeerSession.listWorkspaces()`, picker dialog (workspace list) in `PeerDebugMenu`, and `PeerRelayWorkspaceWindowController` which recursively walks the layout and builds an NSSplitView tree with one `PeerRelaySession` + Ghostty surface per leaf. Each leaf opens its own connection so per-pane disconnect doesn't cascade. |

**Known limitations (Phase W' candidates):**
- Layout drift: divider position / pane add+remove on the host after
  attach is not reflected on the client (snapshot-once).
- bonsplit's per-pane tabs (multiple TabItems per pane) are collapsed
  to the selected tab only.
- Each leaf burns a full handshake on its own connection. Fine for
  unix-socket / SSH-multiplexed transports; may want pooling later.

---

## Open TODOs

### P1 — nice to have before Phase D

- [x] **Relay socket cleanup on crash** — `PeerRelaySession.sweepStaleRelaySockets()`
      runs in `AppDelegate.applicationDidFinishLaunching` and removes
      `/tmp/tm-peer-relay-*.sock` files whose listener is gone
      (`connect()` returns `ECONNREFUSED`). Live sockets owned by other
      debug instances are left alone.
- [ ] **Workspace layout updates** — propagate split-resize / pane
      add+remove from host to attached workspace clients (Phase W').
- [ ] **Snapshot styling** (deferred) — current `readPaneSnapshot` sends
      plain text. The clean fix is a per-cell read with styling, but
      libghostty doesn't expose cell metadata via `ghostty_surface_*`
      yet. SIGWINCH wiggle / Ctrl-L injection both work but disturb the
      host's local viewer because they go through the shared PTY.
- [ ] **Error UX** — relay errors currently show an NSAlert; merge with
      Phase D's main UI integration.

### P2 — Phase D prep

- [ ] Remove `#if DEBUG` guards from PeerRelaySession,
      PeerRelayWindowController, PeerRelayWorkspaceWindowController,
      GhosttyPaneSurfaceProvider.
- [ ] Auto-start peer server at app launch (no manual menu step required).
- [ ] Surface relay window in main UI (not just debug menu).
- [ ] Bonjour discovery for host socket path.
- [ ] SSH transport behind the same `connectAndList` API (only the
      stage-1 dial changes).
