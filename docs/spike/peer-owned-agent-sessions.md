# Peer-owned agent sessions

A project placed on a peer currently comes up with its members running on that
machine and owned by *this* one. The peer's window can show them (PR #196), and
that is as far as the current shape goes: the process is a child of this app's
ssh, so it dies when this app quits, and the peer can never be the machine that
continues the work.

This note records what was measured before designing, so the next attempt does
not start from guesses.

## What is true today

**The process belongs to the host's ssh.** `AgentSession.remoteClaudeLaunch`
and `remoteBridgeLaunch` build a `Launch` whose executable is `/usr/bin/ssh`.
The remote CLI's stdin/stdout *are* that pipe. Nothing is created on the peer —
no FIFO, no pane, no session record.

**A macOS peer cannot host an ensured surface.** `PeerSurfaceProvider` (Swift)
declares `listSurfaces`, `attach`, `listWorkspaces` — and no `ensure`. The
`EnsureSurfaceRequest` handler lives only in `daemon/term-meshd/src/peer/
connection.rs`. A Linux peer serves the peer socket from the daemon and has it;
a macOS peer serves it from the app and does not.

**The daemon on a macOS peer dies with the app.** `term-meshd` runs as the
app's child (verified: ppid of the daemon is the app), and
`applicationWillTerminate` terminates it deliberately —
`Sources/TermMeshDaemon.swift` case 1, "We spawned the daemon — terminate
directly", escalating SIGTERM → SIGKILL.

**Multiple viewers of one surface are already supported.** `attached` /
`attachments` are *per-connection* state on both sides, so two connections may
each attach to the same surface; only a second attach on the same connection is
refused as "already attached". The daemon's resize path says so outright:
"winsize arbitration (min across attachers, tmux-style)".

**The app already knows how to render someone else's surface.**
`PeerPaneSession.attach` + `term-mesh-peer-relay` is the path a remote pane
takes today. Nothing about it requires the surface to be on a different machine.

**One PTY cannot serve both audiences.** A human at the peer wants the CLI's
interactive UI; this app's `AgentPanel` wants NDJSON. Both machines read the
same PTY bytes, so a pane running the TUI leaves nothing to parse, a pane
running the bridge shows an event dump, and a render filter transforms the
bytes for everyone. This is why PR #196 traded the panel for peer visibility,
and why getting both back needs an owner that can serve two different views.

## Shape

Give the session an owner that is neither viewer:

```
peer's term-meshd  (independent of any app)
    ├── agent PTY  (keyed, restartable)
    └── leader PTY
          ▲                    ▲
    peer's own app        another machine
    (attaches, detaches)  (attaches, detaches)
```

Every leg reuses something that exists: `EnsureSurface` for the keyed session,
the peer protocol's multi-viewer attach for the two readers, and
`PeerPaneSession.attach` for the app's own rendering — pointed at its own
machine's daemon rather than a remote one.

## Order of work

Each step is worth doing alone and ends somewhere observable.

Steps 1–3 are done. What each one turned out to need is recorded with it,
because two of the three needed far less than this note first assumed.

1. **Decouple the daemon's lifetime.** *(done — `60b6669e`)* Stop terminating it in
   `applicationWillTerminate`; adopt a running daemon on start instead of
   assuming ownership. Observable: kill the app, `term-meshd` survives, restart
   the app, it reuses the same daemon.

   The mechanism already existed — omitting `TERMMESH_OWNER_PID` leaves
   `wait_for_owner_exit` waiting forever. What was missing was deciding when to
   use it, so the change is a policy and its two call sites. Measured on a Mac
   peer: app killed, daemon kept its pid; app restarted, adopted the same one;
   daemon count stayed 1.

2. **`ensure` on a macOS peer.** *(done — `611b5ab9`)* No routing was needed:
   the daemon serves the whole peer protocol when `TERMMESH_PEER_SOCKET` names
   a path, which is how a Linux peer works. Setting it on the same condition as
   step 1 was the entire change — a session nobody can reach and a session that
   dies at a quit are the same non-feature. Measured: the daemon advertises
   `surface.ensure.v1`, `EnsureSurface` returned CREATED, and the spawned
   process's parent was the daemon rather than the app. With step 1, killing
   the app left both daemon and session running and a restart found the same
   two.

3. **The app as a viewer of its own daemon.** *(done — no product change)*
   Already possible and unused. `PeerPaneHostSpec.direct(sockPath:)` is a plain
   local socket, and the self-attach guard compares against the *app's* peer
   socket, so the daemon's is a different path and passes — correctly, since
   the daemon's surfaces are not the app's and no loop exists. Measured: a
   session created on the daemon by a client that was not the app, opened via
   `debug.peer.open_remote_pane`, and the pane rendered its output.

   That the remaining steps are about *choosing* this path rather than building
   it is the main thing this spike established.

4. **Place a remote member on it.** `attachRemoteAgent` asks the peer to ensure
   a session instead of spawning over ssh. Observable: the member appears on
   both machines and survives the host disconnecting.

5. **Return the native panel.** With an owner that can serve two views, the
   `AgentPanel` reads the structured stream while the peer's pane renders it.
   This is the step PR #196's tradeoff was deferring.

Steps 1–3 are about the peer machine alone and can be verified without any
project. Only step 4 needs two machines.

## Risks worth naming early

- **Adopting a daemon this app did not start** means version skew between app
  and daemon becomes ordinary rather than exceptional. There is already a
  version-skew note in `tm-agent`; it was ignored once during this
  investigation while it was telling the truth. It needs to be actionable, not
  advisory.
- **A surviving daemon holds PTYs after the last viewer leaves.** Reclaiming
  them is `tm-agent gc`'s problem, and it does not know about ensured surfaces
  yet.
- **`isPipeOnly` CLIs** (cursor, agy) have no interactive UI, so step 5 gives
  them nothing to show on the peer. They stay panel-only, which is a property
  of the CLI.
