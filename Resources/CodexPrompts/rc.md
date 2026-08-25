---
description: "term-mesh rc — expose or hide this pane on the tailnet mobile page"
---

# /rc — Codex Mobile Remote Control Shim

User provided: $ARGUMENTS

Use this prompt as the Codex wrapper for `/rc`. All operations must use `tm-agent`; do not use Codex sub-agents or native delegation for term-mesh work.

`.claude/commands/rc.md` is the single source of truth. This file is a compressed IME shim for Codex panes and must not contradict the Claude command.

## Usage

```text
/rc on [--terminal] [--keys safe|none] [--ttl 12h] [--title NAME]
/rc on --agent <name> [--terminal] [--ttl 12h]   # from the leader pane: expose another team agent
/rc off
/rc status [--all]
/rc help
```

`on` exposes this pane. A terminal-backed Claude/Codex session lets the mobile
page switch between Chat and Terminal without changing the local pane. Native
agent panes use Chat, leaders use the request board, and plain shells use
Terminal only. `--terminal` forces the mirror. `--agent` takes this pane's own agent when NAME is omitted;
naming another agent needs the leader pane (or `--team`).

If the first token is `help`, print this usage block and stop.

## Execution

Pass the arguments through unchanged; `$ARGUMENTS` already starts with the subcommand, so never repeat it:

```bash
tm-agent remote $ARGUMENTS         # /rc on --keys none  →  tm-agent remote on --keys none
```

Show the output verbatim (URL, keys, expiry). Run `"$TERMMESH_APP_BIN/tm-agent"` first (the pane environment names the running app's own binary), then `tm-agent` in PATH; an older binary answers `unrecognized subcommand 'remote'`. Do not guess `/Applications/…` paths.
Invoke the selected binary directly and let the tool capture stdout, stderr,
and the exit code. Do not use `output=$(...)` or assign `status=$?`: `status` is
read-only in zsh, and that wrapper can hide the real command result.

After `on`, tell the user in one or two lines: the printed URL (loopback on the Mac; from a phone it is `https://<mac-hostname>.<tailnet>.ts.net/t/<surface_id>` once `tailscale serve --bg 9877` is active), and, if the output says the listener is disabled, that it must be enabled in Settings (Mobile remote control) or with `TERM_MESH_MOBILE_ENABLED=1` before the daemon starts.

Do not retry, poll, or change team membership.

## What the exposure means

- Team agent pane (default inside a native agent pane): the phone shows the structured transcript as a chat, sends whole turns, and can interrupt. A pane running Claude or Codex by hand is not a team agent and gets the mirror.
- Leader pane: phone text arrives as a durable leader request with the usual wake instruction; take it as you normally do.
- A terminal-backed Claude/Codex pane can switch between Chat (whole turns + session transcript) and Terminal (screen + keys). Other panes use `safe` keys for prompts and menus.
- For a terminal-backed pane, `--keys none` keeps screen and transcript reading available but blocks pane text, Chat turns, interrupts, and the key row. Native Agent and Leader semantic APIs are outside this terminal-input policy.
- Only this pane's screen text is visible to the phone. `/rc off`, closing the pane, or the TTL removes the exposure.

## Failure modes

- `no surface id`: pass `--surface <TERMMESH_SURFACE_ID>`.
- `no app socket for this surface`: pass `--app-socket /tmp/term-mesh.sock`.
- `no term-meshd socket found`: the daemon is not running; check `tm-agent doctor`.
