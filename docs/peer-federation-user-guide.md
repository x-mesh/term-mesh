# Peer Federation — User Guide

Last updated: 2026-05-06
Branch: `feat/peer-federation`

Peer federation lets one term-mesh.app instance ("client") attach to
another instance ("host") and keep working in the host's panes as if
they were local. The original goal was *"Mac mini의 term-mesh pane을
맥북의 term-mesh로 이어간다"* — desktop-to-laptop pane handoff —
which the current implementation supports end-to-end, plus quite a
bit more.

This document is the practical primer. For protocol-level details
see `peer-federation-protocol.md`; for phase-by-phase status see
`peer-federation-impl-status.md`; for the original design charter
see `peer-federation.md`.

---

## What you can do today

1. **Mirror a host pane in a Ghostty window.** Pick any pane the
   host exposes, get a real Ghostty terminal back on the client that
   renders the host's PTY stream and forwards your keystrokes.
2. **Mirror a whole workspace with the host's split layout.** A
   single window on the client reproduces the host's bonsplit tree
   (NSSplitView), one Ghostty surface per leaf, with live PTY
   streams in every pane.
3. **Drive the host from inside the client.**
   - **Cmd+D / Cmd+Shift+D** — split the focused pane horizontally /
     vertically. The host runs the split via bonsplit; the new pane
     appears in both windows.
   - **Cmd+W** — close the focused pane on the host.
   - **Cmd+T** — create a new terminal tab inside the focused pane's
     bonsplit pane. The new tab becomes selected so the relay swaps
     to a fresh shell.
   - **Drag the divider** between two panes — the host's matching
     divider follows.
   - **Click a pane** — the host's bonsplit moves keyboard focus to
     the same pane, but does not yank the client's window forward.
4. **Track activity at a glance.**
   - Host panes that are currently being relayed have a teal ring
     drawn around them (reference-counted across multiple clients).
   - The host's status-bar icon grows a small blue dot whenever the
     local peer server is listening; tooltip says "Peer server: on".
5. **Reach the host across the network.**
   - SSH transport tunnels the host's Unix socket through `ssh -L`,
     so any machine you can SSH into can act as a host.
   - Bonjour LAN discovery advertises hosts on the same network so
     the client's connect dialog autofills the SSH target without
     typing aliases.
   - Recent hosts (most-recent-first) are remembered in the connect
     dialog so reconnecting is one keystroke.

---

## Setting up a host

The peer server is opt-in. Three ways to enable it:

1. **Settings → Peer Federation → Enable peer server.** Toggling on
   immediately starts the server. Toggle "Auto-start at app launch"
   if you want it up automatically every time the app starts.
2. **Status-bar menu → Start Peer Server…** for a one-shot session.
3. **Environment variable** (useful for integration tests):
   `TERMMESH_PEER_SERVER_PATH=/tmp/termmesh-app-peer.sock` (the
   legacy `TERMMESH_DEBUG_PEER_SERVER_PATH` still works).

When the server is up:
- It binds the local Unix socket from Settings (default
  `/tmp/termmesh-app-peer.sock`).
- It publishes a Bonjour service named after Settings → "Display
  name" (defaults to the Mac's hostname). The TXT record carries
  the socket path.
- The status-bar icon grows the blue activity dot.
- Any other term-mesh.app on the LAN can find this host in its
  connect dialog without manual configuration.

---

## Connecting from a client

Status-bar menu → **"Connect to Peer Workspace via Ghostty Relay (SSH)…"**.
The dialog offers three ways to fill the SSH target / remote socket
fields:

1. **Recent** picker — last successful connections, most recent
   first. The dialog also pre-fills the fields with the most recent
   one, so re-connect is a single keystroke.
2. **Discovered on LAN** picker — Bonjour-advertised hosts found on
   the network. Selecting one fills the SSH target with the
   advertised hostname and the remote socket from the TXT record.
3. **Manual** — type any SSH target (`user@host`, ssh-config alias,
   `localhost` for self-loop testing) and remote socket path.

Connect runs `ssh -N -T -L <local>:<remote> <target>` in the
background and waits for the local forwarded socket to appear.
Then the workspace picker pops (skipped when the host has only one
workspace), and the relay window opens with the host's split
layout.

Connection state mirroring:
- The relay window's title prefixes with "Peer Workspace · ".
- Each pane the client attaches lights up the teal ring on the
  host side; closing the relay window or detaching takes the ring
  off after the last attach drops.

---

## Architecture (one paragraph)

The host runs a Swift `PeerServer` actor on a Unix socket and
exposes its panes via `GhosttyPaneSurfaceProvider`, which wraps
`tabManager.tabs[*].bonsplitController.treeSnapshot()` and the
underlying `TerminalSurface` PTY callbacks. A length-prefixed
protobuf protocol (`peer/v1/peer.proto`) carries handshake,
surface listing, attach, and PtyData / Input / Resize frames. The
client's `PeerSession` opens the socket via either a direct
`UnixSocketTransport` or an `ssh -L`-tunneled local socket, lists
workspaces, and asks the host to attach the leaves it cares
about. Each leaf gets its own `PeerRelaySession` driving a
`term-mesh-peer-relay` binary that Ghostty hosts as the surface's
"shell"; the binary forwards stdin keystrokes and stdout PtyData
through a small framed protocol on a per-window Unix socket.
Layout updates push back via `WorkspaceLayoutChanged` so the
client's NSSplitView tree patches itself in place when the host's
bonsplit changes (Phase W'). Control commands — split, close,
focus, divider drag, new tab — flow back to the host on the same
session as `WorkspaceControl` envelopes (Phase D-6 / D-7).

Useful entry points if you want to read the code:
- `proto/peer/v1/peer.proto` — wire schema (Swift + Rust bindings
  regenerated by `./scripts/gen-swift-proto.sh` and `cargo build`).
- `swift/PeerProto/Sources/PeerProto/` — `PeerSession` (client),
  `PeerServer` (host), `UnixSocketTransport`, framing helpers.
- `Sources/PeerRelaySession.swift` — bridges PeerSession to the
  relay binary's framed Unix socket.
- `Sources/PeerRelayWorkspaceWindowController.swift` — NSWindow +
  NSSplitView tree, key/click monitors, control dispatch.
- `Sources/GhosttyPaneSurfaceProvider.swift` — host-side bridge from
  bonsplit / TerminalPanel into the protocol.
- `Sources/PeerServerHost.swift` — server lifecycle, Bonjour
  publisher, layout-change bridge.
- `Sources/PeerSSHTunnel.swift` — `ssh -L` subprocess manager.
- `Sources/PeerBonjour.swift` — NetService publisher / browser.
- `daemon/term-mesh-peer-relay/src/main.rs` — Rust shim Ghostty
  spawns as the surface "shell".

---

## Build / distribution

The CI workflow `.github/workflows/ghostty-prebuild.yml` builds
GhosttyKit.xcframework on every push that touches the ghostty
submodule and uploads it as a `ghostty-prebuilt-<sha>` release
artifact. `scripts/setup.sh` falls back to fetching that artifact
on cache miss before attempting a local zig build, so contributors
on machines where zig 0.15.2 is incompatible with the host SDK
(notably macOS 26) can still set up a working tree.

Override knobs:
- `TERMMESH_GHOSTTY_PREBUILT_REPO` — point setup.sh at a different
  fork's release feed.
- `TERMMESH_GHOSTTY_NO_PREBUILT=1` — force a local zig build, even
  when the prebuild is available (useful while iterating on
  ghostty itself).

---

## Known limitations

- **Snapshot styling** — the initial-attach snapshot only carries
  plain text, no colors or cursor position; full-screen TUIs (vim,
  less, htop) show the right text but lose styling until they
  redraw. SIGWINCH / Ctrl-L injection would fix that but disturbs
  the host's local viewer.
- **Scrollback on attach** — only the live viewport is replayed;
  scrollback is lost.
- **Authentication** — anything that can reach the host's Unix
  socket (or SSH into the host) can attach. Production deployment
  needs a pairing / token step.
- **Sidebar entry** — recent hosts live inside the connect dialog
  only; there's no native "Connections" panel listing live relay
  windows / quick-disconnect actions yet.
- **Native TCP transport** — SSH is the only off-host wire today.
  LAN clients could in principle skip SSH once auth lands.

---

## Phase journey

End-to-end the feature landed in roughly these phases (see
`peer-federation-impl-status.md` for the granular checklist):

| Phase | Outcome |
|-------|---------|
| A | Wire protocol + transport library (`PeerProto` Swift package). |
| B | term-meshd Rust peer server, term-mesh-peer-relay shim. |
| C-1 / C-2 | Swift `PeerSession`, debug console window. |
| C-3 | Swift peer server inside term-mesh.app (`PeerServer`, `GhosttyPaneSurfaceProvider`). |
| C-4 | Single-pane Ghostty relay window (real surface renders host PTY stream). |
| C-4 polish | Surface picker, peer-attached teal ring, viewport snapshot, key-event routing fixes (Enter, Ctrl-C, Tab, arrows, ICRNL relay-stdin). |
| W | Layout-preserving workspace relay — recursive WorkspaceLayout proto + NSSplitView reconstruction. |
| W' | Live workspace layout sync — host bonsplit changes push to clients. |
| D-1 / D-2A | Drop `#if DEBUG` guards, rename `PeerDebug*` → `Peer*`. |
| D-2B / D-2C / D-2D | Settings pane, recent-hosts picker, status-bar activity dot. |
| D-3a | Bonjour LAN discovery (publisher + browser). |
| D-4 | SSH transport via `ssh -L` tunnel. |
| D-5 | CI prebuilt GhosttyKit.xcframework + setup.sh fallback. |
| D-6 | Workspace control plane: split / close from relay. |
| D-7a / b / c | Divider drag sync, focus sync, Cmd+T new tab. |
