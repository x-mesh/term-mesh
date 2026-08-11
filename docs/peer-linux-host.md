# Linux Server as a Peer Host (tmux replacement)

Last updated: August 11, 2026
Status: peer host and deterministic runner verified end-to-end (Ubuntu 25.10, x86-64)

A Linux box can serve terminal sessions to term-mesh on your Mac with **only
`term-meshd` installed** — no GUI app, no relay binary on the server. The daemon
owns the PTYs itself (`libc::forkpty`), so the shells keep running when you close
the laptop, the SSH connection drops, or the client detaches. That is what makes
this a tmux replacement rather than a remote-viewing toy.

## The shape of it

```
[ Linux server = HOST ]                       [ macOS = CLIENT ]
term-meshd                                     term-mesh.app
  ├ peer socket (see below)       ←ssh -L→       ├ PeerSSHTunnel (owns the ssh process)
  ├ forkpty: shell, logs, …                      └ term-mesh-peer-relay (pane shell, local)
  └ HTTP dashboard → 127.0.0.1:9876  ←ssh -L→   └ browser → http://127.0.0.1:19876
```

`term-mesh-peer-relay` is **not** a server component despite the name — it is a
local shim that Ghostty spawns as the "shell" of a remote pane. Nothing but
`term-meshd` goes on the Linux side.

## Server setup

### Quick install (recommended)

One command installs the latest release. With a reachable user systemd bus it
registers a `systemd --user` service and enables lingering (so it survives
logout and boots without an interactive login):

```bash
curl -fsSL https://raw.githubusercontent.com/x-mesh/term-mesh/main/scripts/install-linux.sh | bash
```

The exact paths and commands depend on the selected scope:

| Scope | Binary | Config | Unit | Peer socket | Service commands |
|---|---|---|---|---|---|
| User (default) | `~/.local/bin/term-meshd` | `~/.config/term-mesh/peer.env` | `~/.config/systemd/user/term-meshd.service` | `/run/user/<uid>/tm-peer.sock` | `systemctl --user …`; `journalctl --user …` |
| System (root installer) | `/usr/local/bin/term-meshd` | `/etc/term-mesh/peer.env` | `/etc/systemd/system/term-meshd.service` | `/run/term-mesh/tm-peer.sock` | `systemctl …`; `journalctl …` |

The daemon runs as the connecting account by default. This keeps SSH project
setup, file ownership, HOME/PATH, and pane processes under the same identity:
a normal account with a user bus gets a user service, `sudo` keeps `SUDO_USER`
as the system service's `User=`, and a direct `root@host` install runs as root.
To isolate a system install under a dedicated account instead, set
`TERMMESH_SERVICE_USER=term-mesh`; panes then run as that account too and the
SSH account must be root or the same account to pass the peer socket UID gate.
Running the installer as root always selects system scope, including CentOS
7/systemd 219 SSH sessions without a user bus. A non-root install with no user
bus exits with a `sudo` command that preserves the connecting account instead
of silently creating a service under a different identity.

In either scope the peer socket is live immediately. No separate "declare
surfaces" step is required; a single default `$SHELL -l` surface starts if
`TERMMESH_PEER_SURFACES` is unset (see [Run](#run) below for the format).

To add surfaces or change the socket path, edit the matching config and restart:

```bash
$EDITOR ~/.config/term-mesh/peer.env
systemctl --user restart term-meshd
# system scope instead:
sudo $EDITOR /etc/term-mesh/peer.env
sudo systemctl restart term-meshd
```

Re-running the install command is safe — it updates the binary, replaces the
unit file, and restarts the service, but never touches an existing
`peer.env`. Supports both `x86_64` and `aarch64`; the script detects the
architecture and fetches the matching release asset. Requires systemd (most
mainstream distros) — see [Build from source](#build-from-source) for hosts
without it.

Useful commands once installed (omit `--user` for system scope):

```bash
systemctl --user status term-meshd
journalctl --user -u term-meshd -f
# system scope: sudo systemctl status term-meshd
#               sudo journalctl -u term-meshd -f
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

#### Connection ceiling

`TERMMESH_PEER_MAX_CONNECTIONS` caps how many peer connections the host will
hold at once (default 64). This is not a pane limit, but it acts as one: each
attached pane holds a connection for its whole lifetime, and workspace mirrors,
consoles and short-lived surface probes draw from the same pool — so the panes
a client can keep open is this number minus whatever else it has connected.

Raise it on a host you drive with many panes at once. When the ceiling is hit
the daemon closes the new client immediately, and the client sees only its
handshake read returning EOF (`unexpectedEof`) — indistinguishable from a dead
host, so the daemon log is the only place the real cause is recorded:

```
peer connection limit reached (64); closing new client — raise
TERMMESH_PEER_MAX_CONNECTIONS to allow more
```

Read once at startup, so a change needs a daemon restart. A value that is not a
positive integer is ignored with a warning and the default is used.

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
| Remote socket | `/run/term-mesh/tm-peer.sock` for the root-installed system service; non-root user services may leave this empty for auto-detection (see below) |

**Auto-detect:** when the socket field is left empty, the app runs one
short-lived ssh command against the target that checks, in order:

1. `TERMMESH_PEER_SOCKET` in `~/.config/term-mesh/peer.env` (the user-scope
   installer config; last assignment wins)
2. `$XDG_RUNTIME_DIR/tm-peer.sock`
3. `/run/user/<uid>/tm-peer.sock` (the installer default)
4. `/tmp/term-mesh-peer-<uid>/peer.sock` (the macOS host default)

The first live socket wins and is what gets stored in the recent-hosts
list. Hosts with a custom socket path outside `peer.env` still need the
path typed once — after that, recents carry it.

The system-scope socket `/run/term-mesh/tm-peer.sock` and config
`/etc/term-mesh/peer.env` are intentionally outside this per-login probe. Enter
that socket path explicitly on the first connection; the recent-host entry
then remembers it.

The app spawns and owns the `ssh -N -T -L …` process, and reconnects with
exponential backoff (capped at 30 s) across sleep/wake, network blips, and
server reboots. There is no separate auth step: the protocol's `ssh-passthrough`
method trusts the SSH transport, so if you can `ssh` in, you are authenticated.

Recent hosts are remembered (8 max), offered in the connect dialog, and
listed under the menu bar's **Connect to Recent Peer** submenu for
one-click reconnects that skip the dialog entirely.

### Open as a pane instead of a window

Check **"Open as a pane in the current workspace"** in the connect
dialog (or right-click a connected host in the sidebar's Remote Hosts
section → *Open Surface as Pane…*) to host a remote surface as a normal
Bonsplit pane next to your local ones — one workspace can mix panes
from several hosts. The focused pane's host tints the titlebar, every
remote pane carries a colored top strip and a `title ⌁ host` tab chip,
and a disconnect shows an in-pane banner with Reconnect. Panes to the
same host share one SSH tunnel; closing the last pane closes it.

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

### Deterministic runner verification on jw-server

Verified on `root@jw-server:/app/runner` (Ubuntu x86-64, 2026-07-17).
The commands below use the current root-installer contract: a system service,
`/usr/local/bin/term-meshd`, and `/run/term-mesh/tm-peer.sock`. Captured
IDs, hashes, PIDs, and protocol output remain from that verification run.
`/app/runner` was only the child cwd. The final source build lived at
`/tmp/term-mesh-terminate-build-20260717-095335-44485`.

The installed binary and both backups were measured together:

```bash
ssh root@jw-server 'sha256sum \
  /usr/local/bin/term-meshd \
  /usr/local/bin/term-meshd.backup-terminate-20260717-005536 \
  /usr/local/bin/term-meshd.backup-20260717-002500'
```

```text
572fe367f76484a2823150398d52c09327ae7633f34d2e309897eee1962c3a6c  /usr/local/bin/term-meshd
f47a87c6a396211378457c71dcf9ed978071ee2d9438c730767254e4fefa2e34  /usr/local/bin/term-meshd.backup-terminate-20260717-005536
f83f2d439702846f01ff26bacb24f9d5ab423d1e90864b02ebcd62a7920d6ff5  /usr/local/bin/term-meshd.backup-20260717-002500
```

The fixed runner command is public and reproducible:

```bash
daemon/target/release/tm-agent peer ensure \
  --host root@jw-server \
  --remote-socket /run/term-mesh/tm-peer.sock \
  --key runner-smoke \
  --cwd /app/runner \
  --executable /bin/sh \
  --arg=-lc \
  --arg='exec sleep 3600' \
  --policy on-daemon-restart
```

The initial sequential/concurrent campaign snapshot used checked-in
`tests_v2/peer_client.py:PeerClient.list_surfaces` through an SSH Unix-socket
forward. `SurfaceInfo` carries the full ID, title, and cwd but not the PID, so
the daemon's direct-child `ps` output was captured in the same snapshot. This
is the complete command (run from the repository root):

```bash
export SOCK="/tmp/tm-peer-jw-snapshot-$$.sock"
export CTL="/tmp/tm-peer-jw-snapshot-control-$$"
cleanup() {
  ssh -S "$CTL" -O exit root@jw-server >/dev/null 2>&1 || true
  rm -f "$SOCK" "$CTL"
}
trap cleanup EXIT
ssh -M -S "$CTL" -fN \
  -o ExitOnForwardFailure=yes \
  -o StreamLocalBindUnlink=yes \
  -L "$SOCK:/run/term-mesh/tm-peer.sock" root@jw-server
python3 - <<'PY'
import os
import sys

sys.path.insert(0, "tests_v2")
from peer_client import PeerClient

with PeerClient(os.environ["SOCK"], display_name="jw-runner-snapshot") as client:
    client.handshake()
    print("protocol surfaces:")
    for surface in client.list_surfaces():
        print(
            f"surface title={surface.title} surface_id={surface.surface_id.hex()} "
            f"cwd={surface.cwd}"
        )
PY
ssh root@jw-server '
  main=$(systemctl show term-meshd.service -p MainPID --value)
  printf "daemon children (MainPID=%s):\n" "$main"
  ps -o pid=,ppid=,stat=,args= --ppid "$main"
  printf "daemon child cwd:\n"
  for pid in $(pgrep -P "$main"); do
    printf "pid=%s cwd=" "$pid"
    readlink "/proc/$pid/cwd"
  done
'
cleanup
trap - EXIT
```

The command's original output was:

```text
protocol surfaces:
surface title=runner-smoke surface_id=0728f1f76e3d57619135659f6b477043 cwd=/app/runner
surface title=shell surface_id=a3c249ca37b65c958e0fec5cc950da43 cwd=/root
daemon children (MainPID=1029049):
1029082 1029049 Ss   /bin/sh -c /bin/bash -l
1041564 1029049 Ss+  sleep 3600
daemon child cwd:
pid=1029082 cwd=/root
pid=1041564 cwd=/app/runner
```

The shared exact cwd deterministically correlates protocol surface
`runner-smoke` with PID `1041564`, and surface `shell` with PID `1029082`.
The same command remains a complete pre/post snapshot: after termination its
protocol, raw `ps`, and `/proc/<pid>/cwd` sections omit only the terminated
runner while retaining unrelated children.

Ten sequential calls used one authenticated connection. This complete command
asserts all ten `REUSED` results and one full surface/instance/PID identity:

```bash
export SOCK="/tmp/tm-peer-jw-sequential-$$.sock"
export CTL="/tmp/tm-peer-jw-sequential-control-$$"
cleanup() {
  ssh -S "$CTL" -O exit root@jw-server >/dev/null 2>&1 || true
  rm -f "$SOCK" "$CTL"
}
trap cleanup EXIT
ssh -M -S "$CTL" -fN \
  -o ExitOnForwardFailure=yes \
  -o StreamLocalBindUnlink=yes \
  -L "$SOCK:/run/term-mesh/tm-peer.sock" root@jw-server
python3 - <<'PY'
import os
import sys

sys.path.insert(0, "tests_v2")
from peer_client import PeerClient, pb

with PeerClient(os.environ["SOCK"], display_name="jw-runner-sequential") as client:
    client.handshake()
    outcomes = [
        client.ensure_surface(
            key="runner-smoke",
            cwd="/app/runner",
            executable="/bin/sh",
            args=["-lc", "exec sleep 3600"],
        )
        for _ in range(10)
    ]

assert len(outcomes) == 10
assert all(r.result == pb.ENSURE_SURFACE_RESULT_REUSED for r in outcomes)
identities = {(r.surface_id.hex(), r.instance_id.hex(), r.pid) for r in outcomes}
assert len(identities) == 1, identities
first = outcomes[0]
print("count=10 results=REUSED:10")
print(f"surface_id={first.surface_id.hex()}")
print(f"instance_id={first.instance_id.hex()}")
print(f"generation={first.generation}")
print(f"pid={first.pid}")
print(f"spec_hash={first.spec_hash.hex()}")
PY
cleanup
trap - EXIT
```

The observed output was:

```text
count=10 results=REUSED:10
surface_id=0728f1f76e3d57619135659f6b477043
instance_id=0dd54c7aff464268970bce68d3ba14e5
generation=3
pid=1041564
spec_hash=4e85640a9a0ac4087812418e8b4ac0749a4a3b03dac79ed45979234061d68251
```

Twenty concurrent requests used the checked-in
`PeerClient.ensure_same_surface_concurrently` helper on one authenticated
connection. This is the complete tunnel creation, helper import, 20-call, and
identity assertion command (run from the repository root):

```bash
export SOCK="/tmp/tm-peer-jw-runner-$$.sock"
export CTL="/tmp/tm-peer-jw-control-$$"
cleanup() {
  ssh -S "$CTL" -O exit root@jw-server >/dev/null 2>&1 || true
  rm -f "$SOCK" "$CTL"
}
trap cleanup EXIT
ssh -M -S "$CTL" -fN \
  -o ExitOnForwardFailure=yes \
  -o StreamLocalBindUnlink=yes \
  -L "$SOCK:/run/term-mesh/tm-peer.sock" root@jw-server
python3 - <<'PY'
import os
import sys

sys.path.insert(0, "tests_v2")
from peer_client import PeerClient, pb

with PeerClient(os.environ["SOCK"], display_name="jw-runner-concurrent") as client:
    client.handshake()
    outcomes = client.ensure_same_surface_concurrently(
        20,
        key="runner-smoke",
        cwd="/app/runner",
        executable="/bin/sh",
        args=["-lc", "exec sleep 3600"],
    )

assert len(outcomes) == 20
assert all(r.result == pb.ENSURE_SURFACE_RESULT_REUSED for r in outcomes)
identities = {(r.surface_id.hex(), r.instance_id.hex(), r.pid) for r in outcomes}
assert len(identities) == 1, identities
surface_id, instance_id, pid = identities.pop()
print(f"count={len(outcomes)} results=REUSED:20")
print(f"surface_id={surface_id}")
print(f"instance_id={instance_id}")
print(f"pid={pid}")
PY
cleanup
trap - EXIT
```

The observed output was:

```text
count=20 results=REUSED:20
surface_id=0728f1f76e3d57619135659f6b477043
instance_id=0dd54c7aff464268970bce68d3ba14e5
pid=1041564
```

The conflict check changed only the requested argument:

```bash
daemon/target/release/tm-agent peer ensure \
  --host root@jw-server \
  --remote-socket /run/term-mesh/tm-peer.sock \
  --key runner-smoke --cwd /app/runner --executable /bin/sh \
  --arg=-lc --arg='exec sleep 3599' --policy on-daemon-restart
```

It returned `SPEC_CONFLICT`; surface
`0728f1f76e3d57619135659f6b477043` kept PID `1041564` and its original
instance. Exact attach and stdin-EOF detach used:

```bash
daemon/target/release/tm-agent peer attach \
  --host root@jw-server \
  --remote-socket /run/term-mesh/tm-peer.sock \
  --surface-id 0728f1f76e3d57619135659f6b477043 </dev/null
```

The next ensure returned `REUSED`, PID `1041564`, and instance
`0dd54c7aff464268970bce68d3ba14e5`, proving detach did not terminate it.

The restart/terminate tail was rerun from a clean, runner-absent state. Its
current full snapshot before `runner-smoke` ensure was:

```text
protocol surfaces:
surface title=shell surface_id=a3c249ca37b65c958e0fec5cc950da43 cwd=/root
surface title=shell 1 surface_id=9fb438c217455fcd8bdf9f80eeb164d5 cwd=/root
daemon children (MainPID=1042968):
1043000 1042968 Ss   /bin/sh -c /bin/bash -l
1059373 1042968 Ss   /bin/sh -c /bin/bash -l
daemon child cwd:
pid=1043000 cwd=/root
pid=1059373 cwd=/root
```

The fixed ensure command created the runner before restart:

```json
{"disposition":"CREATED","generation":1,"host":"root@jw-server","instance_id":"723cebd9fabd425391159abef93416b1","ok":true,"pid":1083428,"request_id":"55e894a6f2ffab92a3c1cd72a9eb2588","result":"CREATED","spec_hash":"4e85640a9a0ac4087812418e8b4ac0749a4a3b03dac79ed45979234061d68251","surface_id":"0728f1f76e3d57619135659f6b477043"}
```

Restart verification then used:

```bash
ssh root@jw-server 'systemctl restart term-meshd.service'
daemon/target/release/tm-agent peer ensure \
  --host root@jw-server \
  --remote-socket /run/term-mesh/tm-peer.sock \
  --key runner-smoke \
  --cwd /app/runner \
  --executable /bin/sh \
  --arg=-lc \
  --arg='exec sleep 3600' \
  --policy on-daemon-restart
```

The service PID check produced:

```text
old_main_pid=1042968
service=active
new_main_pid=1083594
```

The observed raw CLI output was:

```json
{"disposition":"RECREATED","generation":2,"host":"root@jw-server","instance_id":"86495fb5026e47cba99a9bc2119bc37f","ok":true,"pid":1083799,"request_id":"14d06e3c31a48de258df695547812af8","result":"RECREATED","spec_hash":"4e85640a9a0ac4087812418e8b4ac0749a4a3b03dac79ed45979234061d68251","surface_id":"0728f1f76e3d57619135659f6b477043"}
```

The stable surface ID plus changed generation, instance, and PID prove that
the declared runner was recreated after daemon restart.

Rerunning the complete `PeerClient.list_surfaces` plus remote direct-child
`ps` snapshot command above immediately before termination produced:

```text
protocol surfaces:
surface title=runner-smoke surface_id=0728f1f76e3d57619135659f6b477043 cwd=/app/runner
surface title=shell surface_id=a3c249ca37b65c958e0fec5cc950da43 cwd=/root
daemon children (MainPID=1083594):
1083621 1083594 Ss   /bin/sh -c /bin/bash -l
1083799 1083594 Ss+  sleep 3600
daemon child cwd:
pid=1083621 cwd=/root
pid=1083799 cwd=/app/runner
```

Only that exact runner was then terminated:

```bash
daemon/target/release/tm-agent peer terminate \
  --host root@jw-server \
  --remote-socket /run/term-mesh/tm-peer.sock \
  --surface-id 0728f1f76e3d57619135659f6b477043
```

The first response was correlated and exact:

```json
{"host":"root@jw-server","ok":true,"request_id":"d8ac6f2789148261d481300f3c6cef02","result":"TERMINATED","surface_id":"0728f1f76e3d57619135659f6b477043"}
```

Rerunning the same complete snapshot command after termination produced:

```text
protocol surfaces:
surface title=shell surface_id=a3c249ca37b65c958e0fec5cc950da43 cwd=/root
daemon children (MainPID=1083594):
1083621 1083594 Ss   /bin/sh -c /bin/bash -l
daemon child cwd:
pid=1083621 cwd=/root
```

The unrelated surface set and process were unchanged. Repeating the exact CLI
command produced a fresh request ID and this second raw response:

```json
{"host":"root@jw-server","ok":true,"request_id":"39b4477c7925608e1fdbfe62bdd992c0","result":"NOT_FOUND","surface_id":"0728f1f76e3d57619135659f6b477043"}
```

The terminated child was checked directly:

```bash
ssh root@jw-server 'kill -0 1083799'; echo $?
```

```text
bash: line 1: kill: (1083799) - No such process
1
```

This proves both that the runner exited and that resource idempotency is
separate from request-ID replay protection. The final deliberate state had no
`runner-smoke`; only the unrelated `shell` surface remained at PID `1083621`
at the end of this test.

The final service was active at PID `1083594`; its installed SHA-256 remained
`572fe367f76484a2823150398d52c09327ae7633f34d2e309897eee1962c3a6c`.
`journalctl -u term-meshd.service` logged request hashes, results,
surface IDs, cwd, error codes, and elapsed time without command arguments or
environment values.

The rollback procedure below was verified syntactically but was **not
executed**, because the deployed build passed. To roll back to the immediately
previous build, then compare the installed hash with the measured expected
hash:

```bash
install -m 755 /usr/local/bin/term-meshd.backup-terminate-20260717-005536 \
  /usr/local/bin/.term-meshd.rollback
mv -f /usr/local/bin/.term-meshd.rollback /usr/local/bin/term-meshd
systemctl restart term-meshd.service
systemctl is-active term-meshd.service
actual=$(sha256sum /usr/local/bin/term-meshd | awk '{print $1}')
expected=f47a87c6a396211378457c71dcf9ed978071ee2d9438c730767254e4fefa2e34
test "$actual" = "$expected"
printf '%s  %s\n' "$actual" /usr/local/bin/term-meshd
```

To return all the way to the original build, substitute
`/usr/local/bin/term-meshd.backup-20260717-002500`; its expected SHA-256 is
`f83f2d439702846f01ff26bacb24f9d5ab423d1e90864b02ebcd62a7920d6ff5`.

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
