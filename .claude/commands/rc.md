# /rc — Mobile Remote Control

현재 pane을 term-mesh 모바일 페이지에 노출하거나 해제합니다. Claude Code `/remote-control`의 term-mesh 판이며, Codex pane에서도 같은 `/rc`를 씁니다. 실체는 daemon의 노출 registry와 loopback listener이고, 이 커맨드는 `tm-agent remote`를 호출하는 스위치입니다. 설계: `docs/mobile-remote-control.md`.

**CRITICAL:** Do NOT use Claude Code native team tools (`TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, `TeamDelete`). All operations route through `tm-agent`.

## Arguments

User provided: $ARGUMENTS

## Usage

```
/rc on [--terminal] [--keys safe|none] [--ttl 12h] [--title NAME]
/rc on --agent <name> [--terminal] [--ttl 12h]     # 리더 pane에서 다른 팀 에이전트를 노출
/rc off
/rc status [--all]
/rc help
```

- **on** — 이 pane을 노출한다. Claude/Codex session을 확인할 수 있는 terminal pane은 웹에서 Chat과 Terminal을 선택할 수 있다. Native agent pane은 Chat, 리더 pane은 durable request 보드, 일반 shell은 Terminal만 제공한다.
- **--terminal** — 채팅 대신 터미널 미러(화면 + 타이핑)로 노출한다. native pane에는 터미널이 없으므로 오류가 난다.
- **--agent [NAME]** — 노출할 팀 에이전트. NAME을 생략하면 이 pane의 에이전트(`TERMMESH_AGENT_NAME`)라서 기본 동작과 같다. 다른 에이전트를 노출하려면 리더 pane(또는 `--team`)에서 NAME을 준다. native가 아닌 에이전트 pane은 터미널 미러로 자동 등록된다.
- **--keys safe|none** — 모바일에서 보낼 수 있는 키. `safe`(기본)는 Enter/Esc/Tab/↑↓←→/y/n/1–9/Ctrl-C 고정 allowlist, `none`은 키 전송 차단. 채팅 뷰에는 키가 없다.
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

Invoke the selected binary directly and let the tool capture stdout, stderr,
and the exit code. Do not wrap it in `output=$(...)`, append `status=$?`, or
otherwise build a shell output-capture wrapper: `status` is read-only in zsh,
and a wrapper failure can hide the command's real result after it already ran.

After `on`, tell the user in one or two lines:

1. The URL printed by the command. On the Mac itself it is the loopback listener (`http://127.0.0.1:9877/t/<surface_id>`). From a phone on the tailnet it is the Tailscale Serve address: `https://<mac-hostname>.<tailnet>.ts.net/t/<surface_id>` once `tailscale serve --bg 9877` is active on the Mac (Phase 2 of the design).
2. If the output says the listener is disabled, the exposure is registered but unreachable: enable it in Settings (Mobile remote control) or start the daemon with `TERM_MESH_MOBILE_ENABLED=1`, then restart the daemon.

Do not retry or poll. Do not change team membership.

## What the exposure means

- **Team agent pane** (`kind=agent`, the default inside a native agent pane): the phone shows the agent's structured transcript as a chat and sends whole turns (`team.send`); it can interrupt the running turn. There is no key row. A plain pane running Claude or Codex by hand is not a team agent and gets the terminal mirror; the command says so.
- **Leader pane** (`kind=leader`): text from the phone arrives through the durable leader request board (`team.leader.send`), exactly like a worker's `tm-agent reply`. You will see the usual wake instruction; take the request as you normally do. Retries with the same request id do not duplicate.
- **Claude/Codex terminal pane** (`kind=pane`, `chat_capable=true`): 웹에서 Chat(whole turn + session transcript)과 Terminal(screen + keys)을 선택한다. 로컬 pane은 계속 terminal이다. 일반 shell은 Terminal만 제공한다.
- The phone only ever sees this pane's screen text (last N lines of scrollback). Nothing else on the machine is exposed. `/rc off`, closing the pane, or the TTL removes the exposure.

## Failure modes

- `no surface id`: not inside a term-mesh pane. Pass `--surface <TERMMESH_SURFACE_ID>`.
- `no app socket for this surface`: `TERMMESH_SOCKET_PATH` is missing (shell started outside term-mesh). Pass `--app-socket /tmp/term-mesh.sock` (the app's control socket).
- `no term-meshd socket found`: the daemon is not running for this app instance. Check `tm-agent doctor`.
- `remote.on: ...` from the daemon: the daemon predates this feature; update term-mesh.
