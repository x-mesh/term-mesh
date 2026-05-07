# Peer Federation Design

Last updated: April 23, 2026
Status: Draft (Phase 0) — not yet implemented

This document defines the charter for **term-mesh ↔ term-mesh peer attach**: the ability to connect from one term-mesh.app instance (the *client*) to another (the *host*) and continue working in the host's panes as if they were local.

## Goals

1. Let a user running term-mesh on machine A attach to a pane running on machine B's term-mesh and keep working in it.
2. Preserve local in-process libghostty performance — remote attach is an additive feature, not a rewrite of local rendering.
3. Make the common case (two Macs on the same LAN) feel Apple-native: Bonjour discovery, one-time PIN pairing, keychain-stored tokens.
4. Reuse the existing socket API and canonical terminology (`window` / `workspace` / `pane` / `surface`) so remote surfaces are indistinguishable from local ones at the API layer.
5. Design the wire protocol so that a future headless `term-meshd --serve` mode can reuse it without breaking clients.

## Non-Goals (explicit)

1. **Session persistence across host quit/crash/reboot.** If the host's term-mesh.app is not running, there is nothing to attach to. Persistence is a separate future feature and MUST NOT be assumed by protocol design.
2. Attach from non-term-mesh clients (raw SSH terminals, iPad, web). These can reuse the protocol later but are not MVP targets.
3. Live collaborative multi-writer editing inside a single surface beyond the simple modes defined in §Concurrency.
4. Cross-platform clients (Linux/Windows). Host and client are both macOS term-mesh for now.
5. Remote file transfer / clipboard sync as a first-class feature. Standard OS mechanisms (AirDrop, Universal Clipboard) are assumed to cover that gap.

## Concepts

Federation introduces three new terms layered on top of existing ones:

1. `host` — a term-mesh.app instance that is exposing one or more surfaces for remote attach.
2. `client` — a term-mesh.app instance that is attaching to a remote host.
3. `remote surface` — a surface owned by a host, mirrored into a client's workspace tree.

The same process can be both a host (for others) and a client (of others) simultaneously.

All existing terms keep their meaning:
- `window`, `workspace`, `pane`, `surface` retain the definitions from `agent-browser-port-spec.md` §Concepts.
- A remote surface is a `surface` for all API purposes; the CLI/socket only needs to surface that its owning host is remote.

## Use Cases

1. **Desktop → laptop handoff.** Mac mini at home runs long builds, dev servers, and AI agent sessions. Author leaves home with a MacBook, opens term-mesh, sidebar shows the mini's workspaces, clicks one, continues working.
2. **AI agent server.** Always-on mini runs parallel Claude Code / Codex sessions. Author monitors and steers from any Mac they happen to be at.
3. **Pair review.** Two developers each running term-mesh; one attaches read-only to the other's pane to watch a live debug session.
4. **Same-user two-machine workflow.** Studio on desk, MacBook on couch; both logged into same Apple ID; switch between them without re-establishing tmux sessions.

## Architecture Overview

The host keeps full ownership of PTYs, libghostty rendering state, and workspace tree. Nothing about local rendering changes.

When a client attaches:
1. Host opens an attach-scoped session over a secure transport.
2. For each subscribed surface, host streams PTY output bytes plus a periodic grid snapshot (for fast re-sync after reconnect).
3. Client runs its own libghostty renderer fed by the host's byte stream. Client sends keyboard input, mouse events, and resize requests back.
4. Workspace tree changes on the host (split added, surface closed, browser panel opened) are pushed to the client as structural events.

Key invariant: **the host is always the source of truth.** The client is a view plus an input forwarder. This avoids bidirectional state reconciliation.

## Transport

Decision deferred to Phase 1, but the two candidates are:

1. **SSH tunnel forwarding a Unix socket.** Zero new auth code. Works through any SSH-reachable network. UX requires the user to manage SSH config. Good for MVP.
2. **Native TLS over TCP with Bonjour discovery and PIN pairing.** Magical LAN UX. Requires us to own the certificate story (keychain, pinning, rotation). Higher engineering cost.

MVP ships (1). Bonjour + TLS arrives in Phase 3 without changing the protocol above it.

## Protocol Skeleton (Phase 1 will finalize)

A framed, bidirectional, duplex message stream. Tentative message types:

1. `Hello` — protocol version, client identity, capability flags.
2. `Auth` — bearer token or challenge-response, bound to the transport.
3. `ListSurfaces` / `SurfaceList` — enumerate what the host exposes.
4. `AttachSurface` / `DetachSurface` — subscribe/unsubscribe with a mode (`read-only` | `co-write`).
5. `PtyData` — raw bytes from host PTY (most frequent message).
6. `Input` — keystrokes and mouse events from client.
7. `Resize` — client viewport changed; host must resize the host-side PTY.
8. `GridSnapshot` — periodic keyframe of current grid + scrollback head, used for reconnect re-sync.
9. `WorkspaceUpdate` — structural changes (split added, surface closed, title/branch/port changed).
10. `Ping` / `Pong` — liveness.
11. `Goodbye` — clean shutdown from either side.

Framing candidates: length-prefixed Protobuf (compact, typed) or MessagePack (dynamic, easy). Choice in Phase 1.

Versioning: `Hello` exchanges a semver string. Host and client must share a compatible major; otherwise the host refuses attach with a descriptive error rendered in the client sidebar.

## Concurrency

Per-surface attach modes:

1. `read-only` — client receives PtyData and WorkspaceUpdate but cannot send Input or Resize. Default when the host user is currently active at the host's own screen.
2. `co-write` — client can send Input and Resize. Multiple writers are allowed but discouraged; the host surfaces a small indicator showing active attach count.
3. `take-over` — client claims sole writer; host locally shows a banner. Single future attempt for this is out of MVP scope.

Resize policy: the host PTY uses the most recent resize from any attached party. If the host's local window and a client disagree, last-writer-wins with a small debounce. A more ambitious policy (letterbox to smallest active viewer) is a post-MVP consideration.

## Security Model

Threats in scope:

1. Unauthorized attach from another machine on the same LAN.
2. Eavesdropping on PTY content (may contain secrets, tokens).
3. Replay of captured auth after token revocation.

Out of scope (relied on OS / user):

1. Malicious local process on either host or client that already has the user's privileges.
2. Physical access attacker with the host unlocked.

Controls:

1. All transports are encrypted end-to-end (SSH for MVP, TLS 1.3 later).
2. Authentication per host: long-lived tokens stored in keychain, minted during a one-time PIN pairing. Tokens are per-client-device and revocable from the host's settings.
3. No attach without prior pairing. No "accept any connection" mode.
4. The host always shows a persistent "N clients attached" indicator when N ≥ 1.

## Reconnection Semantics

1. Host keeps the surface alive regardless of attach state.
2. On client disconnect (network drop, sleep, WiFi switch), host buffers recent PTY output in a ring buffer sized O(100 KB per attached surface).
3. On reconnect within T (default 5 minutes), client re-authenticates and replays the buffered bytes plus a fresh `GridSnapshot` to fill anything older.
4. After T, client re-attaches fresh and accepts scrollback loss for the gap.

Rationale: tmux-over-SSH behavior, adapted to term-mesh's grid model.

## Sidebar UX

Client sidebar gains a section for remote hosts. Visual rules:

1. Local workspaces are unchanged.
2. Remote hosts appear grouped under a header with the host's mDNS name (or manually-configured alias).
3. Each remote workspace shows the host's own sidebar metadata (branch, cwd, port, latest notification) because that metadata arrives over `WorkspaceUpdate`.
4. Connection state is visible per host: green dot (connected), yellow (reconnecting), red with tooltip (error).
5. Notification ring on a remote pane behaves identically to a local one; `⌘⇧U` jumps across both.

## Roadmap (summary; details in follow-up docs)

1. **Phase 0 — this document.** Charter and non-goals locked.
2. **Phase 1 — Protocol spec.** Formal message schema, framing choice, version negotiation rules. Still zero code.
3. **Phase 2 — PoC: SSH tunnel + single pane attach.** Manual SSH config, one remote surface at a time, no discovery UI.
4. **Phase 3 — Pairing and Bonjour.** Native discovery, PIN pairing, keychain tokens. TLS transport optional.
5. **Phase 4 — Workspace tree mirror and multi-surface.** Full remote workspace shown in sidebar, all surfaces attachable.
6. **Phase 5 — Concurrency modes.** `read-only` / `co-write` / `take-over` UX, host-side indicator and consent flows.

Feature persistence across host quit is tracked separately and MUST NOT be conflated with federation.

## Open Questions

1. Should the host restrict which workspaces are exposed (opt-in per workspace) or expose everything by default?
2. Should `tm-agent` commands from the client route to the remote host automatically when the active pane is remote, or require explicit targeting?
3. How does the browser panel (`agent-browser` port) federate — byte stream is wrong for a WKWebView. Likely deferred to its own phase.
4. Is there a reasonable middle-ground for "host is about to quit" that keeps the session alive briefly (e.g., 30s grace period so client can reconnect to another attached client hosting the pane)? Likely no; out of scope.
5. What happens when the host's Mac goes to sleep while clients are attached? Probably clean disconnect + reconnect on wake; verify macOS network behavior.

## Review Checklist (before leaving Phase 0)

1. Goals and Non-Goals agreed upon with maintainer.
2. Canonical terms consistent with `agent-browser-port-spec.md`.
3. No Phase is blocked on Phase N+1 decisions.
4. Security threats in scope are enumerated and have a control.
5. Sidebar UX sketch produces no ambiguity for a new user landing on the app.
