---
name: rc
description: "term-mesh mobile remote control: expose this pane to the tailnet mobile page or hide it again. Use when the user invokes $rc, /rc, or asks to control this pane from a phone."
---

# $rc — Mobile Remote Control (Codex skill)

This is the Codex skill form of term-mesh's `/rc` command. `.claude/commands/rc.md`
is the single source of truth; do not contradict it. All operations go through
`tm-agent`; never use Codex sub-agents or native delegation for term-mesh work.

## Usage

The text after `$rc` is the argument list:

```text
$rc on [--keys safe|none] [--ttl 12h] [--leader] [--title NAME]
$rc off
$rc status [--all]
$rc help
```

If the arguments are `help` or empty, print this usage block and stop.

## Execution

Pass the arguments through unchanged; they already start with the subcommand,
so never repeat it:

```bash
tm-agent remote on --keys none      # from "$rc on --keys none"
tm-agent remote off
tm-agent remote status --all
```

Run `"$TERMMESH_APP_BIN/tm-agent"` first: the pane environment names the
running app's own binary (a tagged development app lives outside
`/Applications`, so never guess that path). Fall back to `tm-agent` in PATH. An
older binary answers `unrecognized subcommand 'remote'`; then try the next
binary rather than another spelling.

Show the command output verbatim (URL, keys, expiry). After `on`, tell the user
in one or two lines: the printed URL (loopback on the Mac; from a phone it is
`https://<mac-hostname>.<tailnet>.ts.net/t/<surface_id>` once
`tailscale serve --bg <port>` is active), and, if the output says the listener
is disabled, that it must be enabled in Settings (Mobile Remote Control) before
the daemon starts.

Do not retry, poll, or change team membership.

## What the exposure means

- Leader pane: phone text arrives as a durable leader request with the usual
  wake instruction; take it as you normally do.
- Any other pane: phone text is typed into this terminal; the safe key row
  (Enter/Esc/Tab/Backspace/arrows/y/n/1–9/Ctrl-C) answers prompts and menus.
- Only this pane's screen is visible to the phone. `$rc off`, closing the pane,
  or the TTL removes the exposure.

## Failure modes

- `no surface id`: pass `--surface <TERMMESH_SURFACE_ID>`.
- `no app socket for this surface`: pass `--app-socket /tmp/term-mesh.sock`.
- `no term-meshd socket found`: the daemon is not running; check `tm-agent doctor`.
