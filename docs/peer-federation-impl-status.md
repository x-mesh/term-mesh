# Peer Federation — Implementation Status

Last updated: 2026-04-24
Branch: `feat/peer-federation`

This document tracks the implementation progress of peer federation phases.
Design doc: `peer-federation.md` / `peer-federation-protocol.md`.

---

## Phase Map (Swift + Rust, in-app proof-of-concept)

All phases are DEBUG-only (`#if DEBUG`) for now. Production integration starts after Phase C-4 is stable.

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
  C-4    — Ghostty relay window (real Ghostty surface shows remote PTY)     🚧 IN PROGRESS
Phase D  — Production integration (non-DEBUG), discovery UI, pairing        ⬜ TODO
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

### Current status (2026-04-24)

- Relay window opens ✅
- Relay binary connects to relay socket ✅
- Bidirectional pump starts ✅ (confirmed by trace log)
- Resize frame (type=0x03) received and forwarded to host ✅
- KeyInput (type=0x02) forwarded to host ✅
- PtyData (type=0x01) forwarded from host to relay binary ✅
- **Ghostty renders the relay binary's stdout** — ❓ unconfirmed (blank window observed)

### Test setup required

The peer server is `#if DEBUG` only (in `PeerDebugServer.swift`). Correct test flow:

1. Open a terminal window in the **c4 debug app**.
2. In c4 debug app → menu → **"Start Peer Server… (debug)"** → path `/tmp/termmesh-app-peer.sock`.
3. In c4 debug app → menu → **"Connect to Peer via Ghostty Relay… (debug)"** → same path.
4. Relay window appears. Type in the relay window or in the host terminal.

---

## Open TODOs (Phase C-4)

### P0 — must fix before C-4 is done

- [ ] **Verify Ghostty renders relay stdout** — relay binary may be writing PTY data correctly but Ghostty may not be rendering it. Needs manual test with correct setup (peer server started first).
- [ ] **Relay binary exit diagnosis** — relay binary exits ~10–28s after connect. Binary log (`/tmp/peer-relay-binary.log`) added; need to capture actual exit reason (`read_frame error` vs `stdout write error`).
- [ ] **Screen replay on attach** — host sends no initial screen snapshot, so relay window starts blank. Need to trigger a redraw on the host side after attach (e.g., send `\x0c` clear+redraw, or add a snapshot mechanism to PeerSurfaceAttachment).
- [ ] **Commit: squash WIP commits** — 6 WIP commits since `dd43802` need to be squashed into a clean C-4 commit.

### P1 — nice to have before Phase D

- [ ] **Remove trace logging** — `/tmp/peer-relay-trace.log` writes and `pLog()` in `PeerRelaySession.swift` are for diagnostics only; remove before production.
- [ ] **Remove binary debug logging** — `rlog!` macro and `/tmp/peer-relay-binary.log` in relay binary; remove before release build.
- [ ] **Relay socket cleanup on crash** — if the app crashes, stale relay socket files accumulate in `/tmp/`. Add cleanup at startup.
- [ ] **Multiple relay windows** — `PeerRelaySession.create()` always picks `surfaces.first`; add surface picker UI.
- [ ] **Error UX** — "host has no attachable surfaces" and other relay errors currently show an NSAlert. Should be surfaced more gracefully.

### P2 — Phase D prep

- [ ] Remove `#if DEBUG` guards from PeerRelaySession, PeerRelayWindowController, GhosttyPaneSurfaceProvider.
- [ ] Auto-start peer server at app launch (no manual menu step required).
- [ ] Surface relay window in main UI (not just debug menu).
- [ ] Bonjour discovery for host socket path.

---

## Diagnostics

```bash
# Swift-side pump trace
tail -f /tmp/peer-relay-trace.log

# Relay binary exit reason
tail -f /tmp/peer-relay-binary.log

# Check relay binary is running
pgrep -l term-mesh-peer-relay

# Check relay socket connections
lsof -U | grep tm-peer-relay
```
