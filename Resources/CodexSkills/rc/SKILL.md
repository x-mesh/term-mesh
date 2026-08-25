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
$rc on [--terminal] [--keys safe|none] [--ttl 12h] [--title NAME]
$rc on --agent <name> [--terminal] [--ttl 12h]   # from the leader pane: expose another team agent
$rc off
$rc status [--all]
$rc help
```

`on` exposes this pane. A terminal-backed Claude/Codex session lets the mobile
page switch between Chat and Terminal without changing the local pane. Native
agent panes use Chat, leaders use the request board, and plain shells use
Terminal only. `--terminal` forces the mirror. `--agent` takes this pane's own agent when NAME is omitted;
naming another agent needs the leader pane (or `--team`).

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

Invoke the selected binary directly and let the tool capture stdout, stderr,
and the exit code. Do not wrap it in `output=$(...)`, append `status=$?`, or
otherwise build a shell output-capture wrapper: `status` is read-only in zsh,
and a wrapper failure can hide the command's real result after it already ran.

Show the command output verbatim (URL, keys, expiry). After `on`, tell the user
in one or two lines: the printed URL (loopback on the Mac; from a phone it is
`https://<mac-hostname>.<tailnet>.ts.net/t/<surface_id>` once
`tailscale serve --bg <port>` is active), and, if the output says the listener
is disabled, that it must be enabled in Settings (Mobile Remote Control) before
the daemon starts.

Do not retry, poll, or change team membership.

## What the exposure means

- Team agent pane (default inside a native agent pane): the phone shows the
  structured transcript as a chat, sends whole turns, and can interrupt. A pane
  running Claude or Codex by hand is not a team agent and gets the mirror.
- Leader pane: phone text arrives as a durable leader request with the usual
  wake instruction; take it as you normally do.
- A terminal-backed Claude/Codex pane can switch between Chat (whole turns +
  session transcript) and Terminal (screen + keys). Other panes use the safe key row
  (Enter/Esc/Tab/Backspace/arrows/y/n/1–9/Ctrl-C) answers prompts and menus.
- Only this pane's screen is visible to the phone. `$rc off`, closing the pane,
  or the TTL removes the exposure.

## Failure modes

- `no surface id`: pass `--surface <TERMMESH_SURFACE_ID>`.
- `no app socket for this surface`: pass `--app-socket /tmp/term-mesh.sock`.
- `no term-meshd socket found`: the daemon is not running; check `tm-agent doctor`.
