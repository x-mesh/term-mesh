---
description: "term-mesh rc — expose or hide this pane on the tailnet mobile page"
---

# /rc — Codex Mobile Remote Control Shim

User provided: $ARGUMENTS

Use this prompt as the Codex wrapper for `/rc`. All operations must use `tm-agent`; do not use Codex sub-agents or native delegation for term-mesh work.

`.claude/commands/rc.md` is the single source of truth. This file is a compressed IME shim for Codex panes and must not contradict the Claude command.

## Usage

```text
/rc on [--keys safe|none] [--ttl 12h] [--leader] [--title NAME]
/rc off
/rc status [--all]
/rc help
```

If the first token is `help`, print this usage block and stop.

## Execution

Run the matching command and show its output verbatim (URL, keys, expiry):

```bash
tm-agent remote on $ARGUMENTS      # /rc on ...
tm-agent remote off                # /rc off
tm-agent remote status [--all]     # /rc status
```

If `tm-agent` is unavailable in PATH, run `./daemon/target/release/tm-agent` instead.

After `on`, tell the user in one or two lines: the printed URL (loopback on the Mac; from a phone it is `https://<mac-hostname>.<tailnet>.ts.net/t/<surface_id>` once `tailscale serve --bg 9877` is active), and, if the output says the listener is disabled, that it must be enabled in Settings (Mobile remote control) or with `TERM_MESH_MOBILE_ENABLED=1` before the daemon starts.

Do not retry, poll, or change team membership.

## What the exposure means

- Leader pane: phone text arrives as a durable leader request with the usual wake instruction; take it as you normally do.
- Any other pane: phone text is typed into this terminal; `safe` keys (Enter/Esc/Tab/arrows/y/n/1–9/Ctrl-C) answer prompts and menus.
- Only this pane's screen text is visible to the phone. `/rc off`, closing the pane, or the TTL removes the exposure.

## Failure modes

- `no surface id`: pass `--surface <TERMMESH_SURFACE_ID>`.
- `no app socket for this surface`: pass `--app-socket /tmp/term-mesh.sock`.
- `no term-meshd socket found`: the daemon is not running; check `tm-agent doctor`.
