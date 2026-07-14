# Linux Server as a Peer Host (tmux replacement)

Last updated: July 14, 2026
Status: verified end-to-end on 2026-07-14 (Ubuntu 25.10, x86-64)

A Linux box can serve terminal sessions to term-mesh on your Mac with **only
`term-meshd` installed** — no GUI app, no relay binary on the server. The daemon
owns the PTYs itself (`libc::forkpty`), so the shells keep running when you close
the laptop, the SSH connection drops, or the client detaches. That is what makes
this a tmux replacement rather than a remote-viewing toy.

## The shape of it

```
[ Linux server = HOST ]                       [ macOS = CLIENT ]
term-meshd                                     term-mesh.app
  ├ peer::serve  → /tmp/tm-peer.sock  ←ssh -L→   ├ PeerSSHTunnel (owns the ssh process)
  ├ forkpty: shell, logs, …                      └ term-mesh-peer-relay (pane shell, local)
  └ HTTP dashboard → 127.0.0.1:9876  ←ssh -L→   └ browser → http://127.0.0.1:19876
```

`term-mesh-peer-relay` is **not** a server component despite the name — it is a
local shim that Ghostty spawns as the "shell" of a remote pane. Nothing but
`term-meshd` goes on the Linux side.

## Server setup

### Quick install (recommended)

One command installs the latest release, registers it as a `systemd --user`
service, and enables lingering (so it survives logout and boots on reboot
without an interactive login):

```bash
curl -fsSL https://raw.githubusercontent.com/x-mesh/term-mesh/main/scripts/install-linux.sh | bash
```

This installs `term-meshd` to `~/.local/bin`, writes a starter config to
`~/.config/term-mesh/peer.env` (just `TERMMESH_PEER_SOCKET`, pointing at
`$XDG_RUNTIME_DIR`), and writes/enables
`~/.config/systemd/user/term-meshd.service`. The peer socket is live
immediately — no separate "declare surfaces" step is required; a single
default `$SHELL -l` surface starts if `TERMMESH_PEER_SURFACES` is unset (see
[Run](#run) below for the format).

To add surfaces or change the socket path, edit the config and restart:

```bash
$EDITOR ~/.config/term-mesh/peer.env
systemctl --user restart term-meshd
```

Re-running the install command is safe — it updates the binary, replaces the
unit file, and restarts the service, but never touches an existing
`peer.env`. Supports both `x86_64` and `aarch64`; the script detects the
architecture and fetches the matching release asset. Requires systemd (most
mainstream distros) — see [Build from source](#build-from-source) for hosts
without it.

Useful commands once installed:

```bash
systemctl --user status term-meshd
journalctl --user -u term-meshd -f
```

### Build from source

Only needed if you're not using the installer above — e.g. building from a
branch, or on a host without systemd.

`term-meshd` needs three paths from the repo root, because `src/http.rs` embeds
the dashboard at compile time via `include_str!` / `include_bytes!`:

```
daemon/          proto/          Resources/dashboard/          Assets.xcassets/
```

Ship all four or the build fails on a missing `index.html` / `128.png`, even
though neither has anything to do with peer. `.github/workflows/release-linux.yml`
builds exactly this way for both architectures on every tagged release.

```bash
# from a checkout on the server (or rsync/git archive these four paths)
cd daemon && cargo build --release -p term-meshd
# → daemon/target/release/term-meshd
```

Only `cargo` + a C toolchain are needed; there are no macOS-only crates.

### Run

The peer server is **opt-in**: without `TERMMESH_PEER_SOCKET` it never starts.

```bash
export TERMMESH_PEER_SOCKET=/run/user/$(id -u)/tm-peer.sock

# One surface per line. Each command runs under `/bin/sh -c`, so `;` and loops
# work as written. Omit this and you get a single `$SHELL -l` surface named "shell".
export TERMMESH_PEER_SURFACES='shell=/bin/zsh -l
logs=journalctl -f
top=htop'

./term-meshd
```

Surfaces respawn on their own: if a shell exits, the next attach brings it back
from the same spec (`PtyManager::get_or_respawn`).

For a real tmux replacement without the installer, register it under systemd
by hand the same way `install-linux.sh` does:

```ini
# ~/.config/systemd/user/term-meshd.service
[Unit]
Description=term-mesh peer host
After=network.target

[Service]
EnvironmentFile=-%h/.config/term-mesh/peer.env
ExecStart=%h/.local/bin/term-meshd
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now term-meshd
loginctl enable-linger $USER   # keep it running after you log out
```

## Connecting from the Mac

Peer menu → connect. Only the SSH target is required:

| Field | Value |
|---|---|
| SSH target | `root@jw-server` — whatever `ssh` already accepts |
| Remote socket | *optional* — leave empty to auto-detect (see below), or type the `TERMMESH_PEER_SOCKET` you set, e.g. `/run/user/1000/tm-peer.sock` |

**Auto-detect:** when the socket field is left empty, the app runs one
short-lived ssh command against the target that checks, in order:

1. `TERMMESH_PEER_SOCKET` in `~/.config/term-mesh/peer.env` (what the
   installer writes and the systemd unit reads; last assignment wins)
2. `$XDG_RUNTIME_DIR/tm-peer.sock`
3. `/run/user/<uid>/tm-peer.sock` (the installer default)
4. `/tmp/term-mesh-peer-<uid>/peer.sock` (the macOS host default)

The first live socket wins and is what gets stored in the recent-hosts
list. Hosts with a custom socket path outside `peer.env` still need the
path typed once — after that, recents carry it.

The app spawns and owns the `ssh -N -T -L …` process, and reconnects with
exponential backoff (capped at 30 s) across sleep/wake, network blips, and
server reboots. There is no separate auth step: the protocol's `ssh-passthrough`
method trusts the SSH transport, so if you can `ssh` in, you are authenticated.

Recent hosts are remembered (8 max), offered in the connect dialog, and
listed under the menu bar's **Connect to Recent Peer** submenu for
one-click reconnects that skip the dialog entirely.

## Dashboard forwarding

`term-meshd` serves an HTTP dashboard — sessions, fleet, team, agent spawn,
process stop/resume, token usage — on **`127.0.0.1:9876`**. On a server that is
exactly the view you want when you are not sitting in front of it.

**The peer tunnel forwards it automatically.** When you connect to a peer host,
the same `ssh` process also carries the dashboard to a free loopback port on the
Mac, starting at **19876**:

```
http://127.0.0.1:19876/     → the remote host's dashboard
```

The port is not 9876 because the Mac's own `term-meshd` already holds that, and
because several peer hosts can be connected at once. Each host gets the next
free port (19876, 19877, …), and a reconnect reuses the port it had so the URL in
your browser stays valid. `PeerSSHTunnel.dashboardURL` exposes it.

Both ends of the forward are loopback-only, and it rides the SSH tunnel peer
already opened — so it adds **no network exposure** beyond what peer itself needs.

Settings (`UserDefaults`):

| Key | Default | Meaning |
|---|---|---|
| `peerFederationForwardDashboard` | `true` | Forward the remote dashboard alongside the peer socket |
| `peerFederationRemoteDashboardPort` | `9876` | The port `term-meshd` serves on, on the *remote* side |

### Why the forward is best-effort

The tunnel runs with `ExitOnForwardFailure=yes`, which means **any** forward that
fails to bind takes the whole ssh process down — including the peer socket. A
dashboard port that lost a race would therefore cost you the terminal session,
which is backwards: the dashboard is a convenience, the peer socket is the point.

So `PeerSSHTunnel` probes for a free port before spawning, and if the spawn still
fails while carrying the dashboard forward, it **retries once without it**. You
get a working peer connection with no dashboard rather than no connection at all.
This is not hypothetical — an occupied 19876 was observed killing the peer forward
during development, which is what motivated the fallback.

### Doing it by hand

If you would rather not use the app's tunnel (or want the dashboard without a
peer session), `~/.ssh/config` does the same thing with no code involved:

```sshconfig
Host jw-server
    LocalForward 19876 127.0.0.1:9876
```

Then any `ssh jw-server` brings the dashboard along.

## Do not bind the dashboard to 0.0.0.0

`TERM_MESH_HTTP_ADDR=0.0.0.0` looks like a shortcut around the tunnel. It is not.
When `TERM_MESH_HTTP_PASSWORD` is unset, `auth_middleware` **passes every request
through** — and the dashboard's routes include `/api/agents/spawn`,
`/api/process/stop`, and `/api/team/create`. Binding it publicly without a
password puts unauthenticated remote code execution on the internet.

The loopback default plus the SSH tunnel already gives you the dashboard at zero
additional exposure. If you truly must bind wider, set
`TERM_MESH_HTTP_PASSWORD` — but prefer the tunnel.

To turn the dashboard off entirely on a server: `TERM_MESH_HTTP_DISABLED=1`.

## What is verified, and what is not

Verified on Ubuntu 25.10 / x86-64 (2026-07-14):

- `term-meshd` builds clean (2 unused-code warnings, 0 errors).
- `forkpty` spawns the declared surfaces as real PTYs (`pts/0`, `pts/7`).
- Handshake → capability advertisement (`ptydata.coalesce.v1`, `replay.ring.v1`)
  → auth → attach → live PTY stream, via `tm-agent peer list` / `peer attach`.
- Peer socket and dashboard forward coexist on one ssh process; the dashboard
  lands on 19877 when 19876 is taken.
- The macOS app connects end-to-end: `ListWorkspaces` returns the synthesised
  workspace, the surfaces render as tiled panes, and the dashboard is reachable
  at `http://127.0.0.1:19876` while the Mac's own daemon keeps 9876.
- **Pane operations work like tmux** (verified live 2026-07-14): the daemon
  serves all six `WorkspaceControl` verbs and advertises
  `workspace.control.v1`. Cmd+D / Cmd+Shift+D split (the new pane runs
  `$SHELL -l` in the source pane's cwd), Cmd+W closes (silently refused on the
  last pane), Cmd+T opens a tab, divider drags land without rebuilding the
  other panes, a shell that exits removes its own pane, the arrangement
  survives reconnects for the daemon's lifetime, and every connected viewer
  sees the same tree (`WorkspaceLayoutChanged` broadcast, 120 ms debounce).
  The startup tiling is only the seed layout; everything after it is yours.
- **`install-linux.sh`'s systemd integration is verified live** (2026-07-14):
  install, re-run (config preserved, unit replaced, service restarted rather
  than double-started), `EnvironmentFile` correctly feeds `TERMMESH_PEER_SOCKET`
  into the running daemon, lingering enabled, and a real `tm-agent peer attach`
  against the systemd-managed instance. The download step itself (the actual
  GitHub release asset fetch) is exercised by `.github/workflows/release-linux.yml`
  on each tagged release, not separately re-verified per doc update.

Known gaps versus tmux:

- **Scrollback is a 64 KB ring buffer** (`PtySurface`), so a re-attach restores
  only the recent tail. There is no copy-mode and no unbounded history.
- **No screen re-sync.** `GridSnapshot` is defined in the protocol but neither
  host implements sending it; the stream is raw `PtyData` bytes only. If it
  desynchronizes, there is no protocol-level repair.
- **Layout resets on daemon restart.** The tree is memory-only by design: the
  PTYs are children of the daemon, so a restart kills the shells anyway —
  persisting the layout past them would restore panes onto dead surfaces.
  Declared (`TERMMESH_PEER_SURFACES`) surfaces come back re-tiled; panes you
  split off do not.

## Running one daemon at a time

Restart the daemon by killing the old instance **and waiting for it to exit**
before binding the new one. A TERM'd daemon's shutdown cleanup unlinks its
socket path — if a new daemon already bound the same path, the straggler
deletes the new socket file out from under it. The daemon keeps serving its
(now unlinked) inode, but every new connect through the path gets ENOENT,
which the Mac side surfaces as `unexpectedEof`. The `start-peer.sh` pattern
that avoids this: `kill -9` every `term-meshd`, poll until none remain, then
remove the socket file and start exactly one.
