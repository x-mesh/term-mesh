# Discord Remote-Control Bridge (via peer surface)

Last updated: July 17, 2026
Status: **PoC design.** Core mechanism (read + write a live peer surface from a
CLI) verified end-to-end on `root@jw-server` (Ubuntu 25.10). Bridge wiring not
yet built.

**Decision (2026-07-17): contract-first, transport-agnostic.** Build the clean
`tm-agent peer` contract (`snapshot` / `send-key` / `attach --plain`) in
term-mesh FIRST. Any frontend — Discord, x-remote, Slack, a mobile relay —
consumes it. A terminal daemon must not hardcode one chat transport; the
Discord/x-remote wiring below is a **deferred consumer example**, not the
near-term deliverable. The first consumer specified on top of this contract
is the tailnet mobile page: see [mobile-remote-control.md](./mobile-remote-control.md).

## Goal

Use **Discord** as the remote UI for a live terminal session running on a Linux
peer host — a drop-in replacement for Claude Code's built-in `/remote-control`,
but going to Discord instead of the Claude mobile app.

One sentence: **stream a live pane's output to Discord, inject input/decisions
from Discord, on the same PTY the human is also using — true back-and-forth.**

## Why the peer surface (not headless, not tmux)

Three Linux substrates were measured this session. All can carry an
inject→receive loop; they differ in *what* they drive:

| Substrate | Read | Write | Shares the human's live session? |
|---|---|---|---|
| tmux | `capture-pane` / transcript jsonl | `send-keys` | separate tmux pane, screen-scrape |
| term-mesh **headless** (`tm-agent create/send/read`) | structured stream-json | `tm-agent send` | no — spawns a **new** `bypassPermissions` agent |
| term-mesh **peer surface** (`tm-agent peer attach`) | screen stream | stdin→Input relay | **yes — the same live PTY the human drives** |

Only the **peer surface** gives the original "왔다갔다 / live mirror" ask: the
daemon owns the PTY (`forkpty`) and exposes it over the peer socket, so the
human (via `term-mesh.app` or locally) and the bridge (via `tm-agent peer
attach`) read and write **one shared terminal**. See
[peer-linux-host.md](./peer-linux-host.md) for the host itself.

## Verified mechanism

On the host, `tm-agent` talks to the peer socket (`$TERMMESH_PEER_SOCKET`,
e.g. `/run/user/0/tm-peer.sock`):

```bash
# enumerate exposed surfaces:  <title> <cols>x<rows> <status> <cwd> <id>
tm-agent peer list  "$PEER_SOCK"
#   shell   135x77   live   /root   [a3c249ca]

# READ  — stdin EOF makes attach dump the current screen and detach
tm-agent peer attach "$PEER_SOCK" --name shell < /dev/null

# WRITE — stdin is relayed to the pane as Input (keystrokes)
printf 'echo hi\n' | tm-agent peer attach "$PEER_SOCK" --name shell
```

`peer attach` is inherently a **two-way pipe**: its stdout is the pane's
terminal output, its stdin is the pane's keyboard. The bridge is just the other
end of that pipe.

Proven this session: listed the surface, read the operator's typed messages,
injected `echo …` that executed, and confirmed the operator saw it — a full
human↔remote round trip on one shared pane.

## Architecture

```
Discord  ⇄  x-remote gateway (Bun; Discord bridge, allowlist, batching)
                 ⇕  WebSocket (envelope protocol, host_id namespaced)
           x-remote host  (on the Linux peer host)
                 │  peer-surface provider  (NEW)
                 ⇩  long-lived `tm-agent peer attach`  (stdout=screen, stdin=input)
           term-meshd peer socket  (/run/user/0/tm-peer.sock)
                 ⇩  forkpty PTY
           live pane  ← the human also drives this
```

Reuse (already built in x-remote): gateway, Discord bridge, envelope
`protocol.mjs`, host enrollment, output batching. **New** is only the
peer-surface provider plus the mention-push path.

## The contract (term-mesh — build this first)

Today's read/write are shell-level hacks: `peer attach </dev/null` for a
one-shot read (then strip escapes with `sed`), `printf | peer attach` for a
write. That works but forces every frontend to screen-scrape. The contract
replaces the hacks with three deterministic `tm-agent peer` subcommands.

**Key point: the wire already supports all of it.** `daemon/peer-proto` (used
in `term-mesh-cli/src/peer.rs`) already defines `ListSurfaces`/`SurfaceList`,
`AttachSurface{mode:CoWrite}`/`AttachResult`, `PtyData` (server→client output),
`Input` (client→server keystrokes), and `Resize`. So the contract is mostly
**client-side convenience in `tm-agent peer`** — no new daemon RPC, except an
optional true snapshot.

| Command | Behavior | Daemon/protocol change? |
|---|---|---|
| `peer snapshot <surface>` | attach → collect the initial repaint (`PtyData` until quiescent, ~150 ms) → strip ANSI/OSC → print the plain current screen once → detach | **No** (client-side approx). *Optional later:* a real `SnapshotSurface`→`SurfaceSnapshot{text}` reading the daemon's PTY grid for exactness |
| `peer send-key <surface> <key>` | attach CoWrite → send one `Input` with the key's bytes (`Enter`=`\r`, `Up`=`\e[A`, `Down`=`\e[B`, `Tab`=`\t`, `1`..`9`, `C-c`=`\x03`, …) → detach | **No** — a name→bytes map over the existing `Input` |
| `peer attach --plain` | live attach, but strip ANSI CSI + `\e]133;…` OSC from `PtyData` before stdout | **No** — client-side filter |

Reference stripper (verified this session): drop `\e[…[a-zA-Z]` CSI,
`\e]133;…\x07` OSC prompt markers, and NULs; keep printable lines.

With these three a frontend gets everything without escape-code guessing:
**read a clean screen** (`snapshot`), **type text** (stdin / `send-key`), and
**drive a menu deterministically** (`send-key Down` / `send-key 2` /
`send-key Enter`). That is the whole term-mesh deliverable; the consumer below
is built entirely on top of it.

### Implementation sketch (term-mesh)

- New subcommands in `daemon/term-mesh-cli/src/peer.rs` alongside `list`/`attach`
  — `snapshot` and `send-key`, plus a `--plain` flag on `attach`.
- A `key_bytes(name) -> Vec<u8>` table (Enter/Up/Down/Left/Right/Tab/Esc/digits/
  C-a..C-z). Reuse the existing attach connect + `AttachSurface{CoWrite}` +
  `Input` send path (peer.rs:1275, 1414).
- `snapshot` = the read path (peer.rs:1321 `PtyData` loop) bounded by a
  quiescence timer, piped through the stripper, printed once.
- Docs + a `peer bench`-style smoke test.

## Deferred consumer: x-remote peer-surface provider

*(Built on the contract above; not the near-term deliverable — shown to prove
the contract is sufficient for a real frontend.)*

A provider alongside `ClaudeProvider` / `CodexProvider` in
`x-remote/lib/x-remote/providers.mjs`, but it **attaches** instead of spawning
— and calls the contract commands (`snapshot`/`send-key`) instead of scraping:

| Provider op | Implementation |
|---|---|
| `attach(surface)` | spawn a long-lived `tm-agent peer attach $SOCK --name <surface>` child; its **stdout** → clean → `output`/`progress` events |
| `steer(text)` | write `text\n` to the attach child's **stdin** (relayed to the pane) |
| `answer(choice)` | write the menu selection keys (e.g. `Enter`, or `2\n`) |
| `interrupt()` | write `\x03` (Ctrl-C) to stdin |
| `read-once` | one-shot `peer attach </dev/null` (or `peer snapshot`) for a fresh dump |

Output cleaning pipeline (proven regex this session): strip `\e[…m`-style CSI,
`\e]133;…` OSC prompt markers, NULs; keep printable lines; feed the existing
`cleanDisplayText` / batching in `protocol.mjs`.

CLI surface (x-remote):

```bash
xm remote peer list                 # tm-agent peer list, surfaced to the operator
xm remote attach --peer <surface>   # register a peer-surface session, publish session.start
xm remote detach <session>
# Discord: !xr steer <session> "..."   → provider.steer  → pane input
#          !xr read  <session>          → provider read-once
```

## Approval / notification — the push alarm

`discord.mjs` currently sets `allowed_mentions: { parse: [] }` (line 33) — **all
mentions suppressed**, so nothing pushes to a phone. Add a `sendAlert(text,
userIds)` path that sets `allowed_mentions.users` and prefixes `<@id>`, and
route only decision-class events through it (the gateway already delivers those
un-batched). Detect a pending decision by:

- **claude panes** — the Notification hook fires when claude waits for input;
  or pattern-match the cleaned screen for a permission menu
  (`Do you want to proceed?` / `❯ 1. Yes`).
- **shell panes** — a bare prompt after a long-running command = idle/needs
  attention (best-effort).

Regular output stays on the quiet `send` path; only approvals mention → phone
push. This mirrors `/remote-control`'s "results quietly, approvals loudly."

## Proven vs. PoC-remaining

Proven this session (no code): `peer list`; read via attach; write via attach;
human↔remote round trip; tmux and headless alternatives; `IS_SANDBOX=1`
requirement for root headless (peer surfaces are unaffected — they run the
operator's own shell).

Remaining for the PoC:

- [ ] peer-surface provider (long-lived attach child; stdout→events; stdin←steer)
- [ ] output cleaning + batching into the envelope protocol
- [ ] `xm remote peer list` / `attach --peer` / `detach`
- [ ] decision detection → `sendAlert` mention push
- [ ] reconnect (attach child dies / socket restarts) and multi-surface addressing

## Risks / open questions

- **Two writers on one PTY** — human + bridge can interleave keystrokes. Fine
  for handoff; messy for truly simultaneous use. Same caveat as sharing a tmux
  pane; document it, don't fight it.
- **Screen-scrape fragility for menu decisions** — mitigated: most approvals are
  the highlighted default (Enter) or a single digit. A `peer snapshot` +
  `peer send-key` contract removes most of the risk.
- **Auth** — the peer socket is a local unix socket; the bridge runs on the same
  host, so no new network exposure. Discord side keeps the existing
  `DISCORD_ALLOWED_USER_IDS` allowlist.
- **Root host** — a root `term-meshd` needs `IS_SANDBOX=1` to run *headless
  claude* agents, but peer surfaces run the operator's shell and are unaffected.

## Related

- [peer-linux-host.md](./peer-linux-host.md) — the peer host (daemon owns PTYs)
- [peer-federation-protocol.md](./peer-federation-protocol.md) — wire protocol
- [x-kit-integration.md](./x-kit-integration.md) — term-mesh ↔ x-kit
- x-remote (x-kit): `x-remote/lib/x-remote-host.mjs`, `providers.mjs`,
  `x-remote/lib/x-remote/discord.mjs`, `protocol.mjs`
