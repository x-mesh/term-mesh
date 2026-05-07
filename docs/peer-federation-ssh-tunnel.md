# Peer Federation over SSH Tunnel

Last updated: April 23, 2026
Status: Phase 2.3 Option A — verified end-to-end on 2026-04-23

The peer-federation protocol (see `peer-federation.md` and `peer-federation-protocol.md`) is transport-agnostic. Before any native Bonjour/TLS work (Phase 3), the easiest way to exercise it across machines is an SSH unix-socket forward. This document describes the setup.

## Why SSH first

1. Zero new authentication code — SSH already handles keys and access control.
2. Works across any network topology SSH reaches (LAN, Tailscale, jump boxes).
3. Lets the protocol ship and stabilize before we own a TLS story.
4. The protocol defines an `ssh-passthrough` auth method that MVP hosts accept, trusting the SSH transport. See `peer-federation-protocol.md` §Auth.

## Requirements

1. OpenSSH 6.7+ on both ends (macOS default, Linux default). Needed for `StreamLocalBind*` unix-socket forwarding over `-L`.
2. `term-meshd` built and available on the host machine.
3. `tm-agent` (Rust CLI from `daemon/term-mesh-cli`) on the client machine.
4. Standard SSH access from client → host (public-key recommended; the demo script uses `accept-new` for host keys).

## One-shot demo script

`scripts/peer-ssh-demo.sh` orchestrates the whole flow end-to-end. It runs against any SSH target, including `localhost` for smoke testing:

```bash
./scripts/peer-ssh-demo.sh localhost
./scripts/peer-ssh-demo.sh user@mac-mini.local
```

What it does:

1. Starts `term-meshd` on the target with `TERMMESH_PEER_SOCKET=/tmp/tm-peer-host-<pid>.sock`.
2. Establishes a backgrounded SSH tunnel: `ssh -L /tmp/tm-peer-client-<pid>.sock:/tmp/tm-peer-host-<pid>.sock`.
3. Runs `tm-agent peer attach <client-sock>`, keeps stdin open for ~4 s so several ticks flow.
4. Cleans up: kills the remote daemon, tears down the tunnel, removes sockets.

Environment overrides: `REMOTE_DAEMON` (path to `term-meshd` on the host), `LOCAL_TM_AGENT` (path to `tm-agent` on the caller). Defaults resolve to `daemon/target/debug/...` of the repo the script lives in.

## Manual steps

If you need to integrate into a custom workflow, run the pieces yourself:

### On the host

```bash
# The socket path is arbitrary; any user-writable location works.
TERMMESH_PEER_SOCKET=/tmp/term-mesh-peer.sock \
  term-meshd &
```

The daemon prints `peer-federation listening on <path>` at info level.

### On the client (or same machine)

```bash
# Forward the host's peer socket to a local path.
ssh -f -N -T -q \
    -o LogLevel=QUIET \
    -o ExitOnForwardFailure=yes \
    -L /tmp/term-mesh-peer-client.sock:/tmp/term-mesh-peer.sock \
    user@host

# Attach.
tm-agent peer attach /tmp/term-mesh-peer-client.sock
```

The client prints a short `[peer] connected...` banner and then streams PtyData from the host straight to stdout. Ctrl-D cleanly detaches.

## What's verified

As of 2026-04-23 against localhost:

1. Full handshake (Hello / AuthChallenge / Auth / AuthResult) survives the SSH byte stream intact.
2. `ListSurfaces` round-trip over the tunnel returns the synthetic `TickSurface`.
3. `AttachSurface` is accepted and `PtyData` frames flow at 1 Hz with no corruption or gaps.
4. Clean detach: client sends `Goodbye`, host logs the clean shutdown, all sockets remove themselves.

The same verification on two physical Macs is still outstanding — nothing protocol-level is expected to differ, but the TIOCGWINSZ path on a real TTY should be exercised once we wire real PTYs in Phase 2.3 Option B.

## Known gotchas

1. **Remote dotfiles that print at shell startup can leak into stdout/stderr** when ssh connects. `ssh -T -q -o LogLevel=QUIET` helps but is not airtight on every machine; the demo script redirects the tunnel's stdio to `/dev/null` after backgrounding because those writes happen before auth anyway and are never protocol payload. If you run the commands by hand, expect occasional shell-greeting chatter on the first invocation — it does not affect the forwarded byte stream.
2. **SSH unix-socket forwarding is unidirectional** in the sense that once the tunnel is up, it works fine both ways, but you need a fresh tunnel per client. There is no `-R` trick that saves a round trip here.
3. **Socket permissions**: the forwarded socket on the client side is created with the user's umask. If you need it writable by another user (rare for dev), set `StreamLocalBindMask` on the client end.
4. **MOTD / PAM welcome output** on some hosts (macOS with Homebrew arm64 warnings, many Linux distros) is sent to ssh stderr and may appear in any interactive ssh invocation. It is cosmetic; production automation should redirect.
5. **Host key prompts** on first connection block the tunnel. The demo uses `accept-new` for smoke tests; production should provision `known_hosts` ahead of time.

## When to move off SSH

SSH is a fine transport and will stay supported indefinitely. The planned move to Bonjour + native TLS (Phase 3) addresses only:

1. Magical LAN discovery — "I don't want to memorize SSH targets".
2. Phones / iPads as clients where SSH clients are awkward.
3. Per-device token revocation UX inside term-mesh itself, surfaced in settings rather than via `~/.ssh/authorized_keys`.

Until then, SSH tunnel is the recommended transport and the integration tests should assume SSH is available.
