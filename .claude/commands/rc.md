# /rc — Mobile Remote Control

현재 pane을 term-mesh 모바일 페이지에 노출하거나 해제합니다. Claude Code `/remote-control`의 term-mesh 판이며, Codex pane에서도 같은 `/rc`를 씁니다. 실체는 daemon의 노출 registry와 loopback listener이고, 이 커맨드는 `tm-agent remote`를 호출하는 스위치입니다. 설계: `docs/mobile-remote-control.md`.

**CRITICAL:** Do NOT use Claude Code native team tools (`TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, `TeamDelete`). All operations route through `tm-agent`.

## Arguments

User provided: $ARGUMENTS

## Usage

```
/rc on [--keys safe|none] [--ttl 12h] [--leader] [--title NAME]
/rc off
/rc status [--all]
/rc help
```

- **on** — 이 pane을 노출한다. 다시 실행하면 entry를 교체하고 TTL을 다시 센다.
- **--keys safe|none** — 모바일에서 보낼 수 있는 키. `safe`(기본)는 Enter/Esc/Tab/↑↓←→/y/n/1–9/Ctrl-C 고정 allowlist, `none`은 키 전송 차단.
- **--ttl** — 노출 시간(`30m`, `12h`, `2d`, 초). 기본 24h, daemon이 60s–7d로 clamp.
- **--leader** — 팀 리더로 등록. 앱이 띄운 리더 pane은 자동 감지되므로 보통 생략한다. adopt한 리더(`TERMMESH_TEAM` 없음)는 `--leader --team ws-<hex>`를 함께 준다.
- **off** — 노출 해제.
- **status** — 이 pane의 노출 상태. `--all`은 daemon의 모든 노출 surface.

## Execution

If the first token is `help`, print the usage block above and stop.

Otherwise pass the arguments through unchanged. `$ARGUMENTS` already starts
with the subcommand (`on`, `off`, or `status`), so do not repeat it:

```bash
tm-agent remote $ARGUMENTS         # /rc on --keys none  →  tm-agent remote on --keys none
```

Show the output verbatim (URL, keys, expiry). Use the `tm-agent` that belongs
to the app this pane runs in — the pane environment names it:

```bash
"$TERMMESH_APP_BIN/tm-agent" remote $ARGUMENTS   # the running app's own binary (preferred)
tm-agent remote $ARGUMENTS                      # PATH fallback (may be an older release)
```

An older `tm-agent` reports `unrecognized subcommand 'remote'`; then try the
next binary rather than another spelling. Do not guess `/Applications/…`
paths: a tagged development app lives elsewhere and `$TERMMESH_APP_BIN` already
points at it.

After `on`, tell the user in one or two lines:

1. The URL printed by the command. On the Mac itself it is the loopback listener (`http://127.0.0.1:9877/t/<surface_id>`). From a phone on the tailnet it is the Tailscale Serve address: `https://<mac-hostname>.<tailnet>.ts.net/t/<surface_id>` once `tailscale serve --bg 9877` is active on the Mac (Phase 2 of the design).
2. If the output says the listener is disabled, the exposure is registered but unreachable: enable it in Settings (Mobile remote control) or start the daemon with `TERM_MESH_MOBILE_ENABLED=1`, then restart the daemon.

Do not retry or poll. Do not change team membership.

## What the exposure means

- **Leader pane** (`kind=leader`): text from the phone arrives through the durable leader request board (`team.leader.send`), exactly like a worker's `tm-agent reply`. You will see the usual wake instruction; take the request as you normally do. Retries with the same request id do not duplicate.
- **Any other pane** (`kind=pane`): text from the phone is typed into this terminal as if at the keyboard. Keys from the `safe` allowlist answer permission prompts and menus (`y`/`n`, digits, Enter, Esc, arrows, Ctrl-C).
- The phone only ever sees this pane's screen text (last N lines of scrollback). Nothing else on the machine is exposed. `/rc off`, closing the pane, or the TTL removes the exposure.

## Failure modes

- `no surface id`: not inside a term-mesh pane. Pass `--surface <TERMMESH_SURFACE_ID>`.
- `no app socket for this surface`: `TERMMESH_SOCKET_PATH` is missing (shell started outside term-mesh). Pass `--app-socket /tmp/term-mesh.sock` (the app's control socket).
- `no term-meshd socket found`: the daemon is not running for this app instance. Check `tm-agent doctor`.
- `remote.on: ...` from the daemon: the daemon predates this feature; update term-mesh.
