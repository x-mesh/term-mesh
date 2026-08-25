# Mobile Remote Control over Tailscale

Last updated: August 25, 2026
Status: Approved design v2, not implemented. Supersedes the 2026-08-21
"Tailscale Serve 기반 모바일 리더 제어면" plan (mem-mesh decision `c0220ed0`).
Code references are against `develop` 7f2be7ad.

Related: [discord-remote-bridge.md](./discord-remote-bridge.md) (contract-first
decision this design consumes), [peer-federation.md](./peer-federation.md),
[peer-linux-host.md](./peer-linux-host.md) (dashboard forwarding precedent),
[native-agent-panes.md](./native-agent-panes.md).

## 0. 결정 요약

1. 제어 단위는 surface(pane)다. team leader는 `kind=leader`인 surface 한 종류이며,
   리더 pane에서만 켜면 "리더만 제어"가 별도 모드 없이 성립한다.
2. 켜는 손잡이는 pane 안에서 치는 `/rc on|off|status` 스킬이고, 스킬은
   `tm-agent remote`를 호출할 뿐이다. 실체는 daemon의 exposure registry와
   모바일 listener다. Claude Code와 Codex는 같은 스킬 파일 쌍을 쓴다.
3. 새 원격 프로토콜을 만들지 않는다. app socket의 `team.read` / `team.leader.send`
   / `surface.read_text` / `surface.send_text` / `surface.send_key`와 daemon의
   per-surface vt100 screen을 재사용한다.
4. listener는 term-meshd 안의 별도 loopback HTTP(기본 `127.0.0.1:9877`)이며 기존
   dashboard(`:9876`)와 Router를 공유하지 않는다. non-loopback bind는 없다.
5. 외부 노출과 사용자 신원은 Tailscale Serve가 맡는다. 인증 모드 기본값은
   `tailscale`(fail closed)이고, `loopback`은 개발 전용이다. Funnel은 지원하지 않는다.
6. 쓰기는 텍스트(durable request 또는 send_text)와 고정 allowlist 키만 허용한다.
7. Phase 1은 Tailscale 없이 localhost에서 끝내고, Phase 2에서 Serve를 붙이며,
   relay(peer host) surface는 Phase 3에서 다룬다.
8. 푸시 알림, 풀 터미널, 구조화 transcript는 v1 범위 밖이다.

## 1. 목표, 범위, 단계

모바일 브라우저에서 term-mesh pane 안의 에이전트(Claude Code, Codex 등) 화면을
읽고 답변 텍스트와 소수의 키를 보낸다. Claude Code `/remote-control`의 term-mesh
판이다. 벤더 relay 없이 tailnet 안에서 동작하고, Codex처럼 동등 기능이 없는 CLI에도
같은 방식으로 적용된다.

### 범위 밖 (v1)

- 푸시 알림
- 브라우저 풀 터미널(xterm.js), 임의 키 입력, WebSocket/SSE 스트리밍
- Tailscale Funnel, 기존 dashboard API의 tailnet 노출
- task create/delegate/approve 같은 팀 제어
- 구조화 transcript(jsonl 채팅 뷰) — v2 후보

### 단계

| Phase | 내용 | 검증 |
|---|---|---|
| 1 | registry, `tm-agent remote`, `/rc` 스킬, loopback listener, 모바일 페이지 | localhost(`auth=loopback`) + mac-sub socket E2E |
| 2 | Tailscale Serve 연동, 신원 헤더 인증, Settings 토글 | tailnet 실기기 |
| 3 | peer host(relay) surface | peer E2E |

## 2. 재사용하는 기존 배선

설계가 기대는 사실은 전부 코드로 확인했다.

| 배선 | 위치 | 이 설계에서의 역할 |
|---|---|---|
| `team.read {agent_name: "leader", lines}` — GUI 리더 pane의 Ghostty scrollback | `Sources/TerminalController.swift` `asyncTeamRead` | 리더 화면 읽기 |
| `team.leader.send {text, request_id?}` — durable leader request board + wake instruction; `team.leader.request.list/take/complete` | 같은 파일 `asyncTeamLeaderSend` | 리더에게 답변, 재시도 idempotent |
| `surface.read_text {surface_id, lines, scrollback}` / `surface.send_text {surface_id, text}` / `surface.send_key {surface_id, key}` | `Sources/TerminalController+Surface.swift` `v2Surface*`, `v2ResolveWorkspace` | 일반 pane 읽기·쓰기·키 |
| GUI pane env: `TERMMESH_SURFACE_ID` = panel UUID, `TERMMESH_DAEMON_UNIX_PATH` = 인스턴스 daemon socket | `Sources/GhosttyTerminalView.swift:750`, `:770` | pane 자기 식별, daemon 도달 |
| daemon surface env: `TERMMESH_SURFACE_ID`(hex), `CMUX_SURFACE_ID`, `TERMMESH_SOCKET`(그 host의 daemon control socket). 내부 identity는 마지막에 덧붙어 client env로 위조 불가 | `daemon/term-meshd/src/peer/surface.rs:2336` `identity_environment`, 적용 `:938`(PTY), `:1176`(agent), precedence 테스트 `:3660` | 원격 pane 자기 식별 |
| daemon socket 경로: `default_socket_path()`가 `TERMMESH_DAEMON_UNIX_PATH`를 존중해 bind | `daemon/term-meshd/src/socket.rs:1116`, `main.rs:455` | 주입값과 실제 경로 일치 |
| `tm-agent`의 daemon socket 해석 순서 `detect_watch_socket` | `daemon/term-mesh-cli/src/tm_agent.rs:12342` | `tm-agent remote`가 재사용 |
| per-surface `vt100::Parser`, GridSnapshot = `contents_formatted()` | `daemon/term-meshd/src/peer/surface.rs:371`, `:410`, `:1870` | headless surface 화면 텍스트(`contents()`) |
| 키 이름→바이트 표 `key_bytes()` (테스트 포함) | `daemon/term-mesh-cli/src/peer.rs:2092` | 키 allowlist 바이트 |
| `ghostty_surface_read_screen_tail_vt` (cmux fork): 최근 N행을 렌더된 셀 스타일이 보존된 VT로 반환, `ghostty_surface_grid_metrics`로 커서 위치 | `ghostty/include/ghostty.h:1635`, `:1407` | 앱 RPC `surface.read_screen_vt` → 색·dim·반전·커서가 있는 화면 |
| daemon RPC 이름 규칙 `watch.on/off/status`, HTTP→app socket proxy `rpc_team_socket` | `daemon/term-meshd/src/socket.rs`, `http.rs` | `remote.*` RPC, listener proxy |
| leader command 설치 관례: Claude command + Codex prompt + managed 목록 + IME alias | `scripts/copy-claude-commands.sh`, `Sources/ClaudeCommandInstaller.swift`, `Sources/GhosttySurfaceScrollView.swift` `imeSlashCommandAliases()` | `/rc` 스킬 설치 |
| peer tunnel이 원격 dashboard를 로컬 `19876+`로 forward | `Sources/PeerSSHTunnel.swift:142-262`, [peer-linux-host.md](./peer-linux-host.md) | Phase 3 relay 경로 |
| Tailscale Serve 신원 헤더 `Tailscale-User-Login`, `Tailscale-User-Name`; tagged device·Funnel 트래픽에는 없음 | Tailscale KB 1312 | 인증 |

## 3. 아키텍처

```
phone (Safari / PWA)
  │  Phase 2: https://<mac>.<tailnet>.ts.net   (tailscale serve → 127.0.0.1:9877)
  ▼
term-meshd mobile listener  127.0.0.1:9877
  │  auth: loopback(dev) | tailscale(Tailscale-User-Login ∈ allowlist)
  │  exposure registry: surface_id → {kind, team, keys, owner, expires}
  ├─ GUI surface ────── app Unix socket ──┬─ kind=leader: team.read / team.leader.send / surface.send_key
  │                                       └─ kind=pane:   surface.read_text / send_text / send_key
  ├─ daemon surface ─── in-process ──────── vt100 contents() / Input
  └─ peer host (Phase 3) ── 기존 SSH forward ── 원격 term-meshd의 같은 listener
```

원칙:

- host가 source of truth다. listener는 읽기 projection과 입력 forwarder일 뿐 상태를
  갖지 않는다(registry와 request_id 중복 방지 창 제외).
- 노출은 surface 단위 opt-in이다. 켜지 않은 surface는 목록에도 없다.
- 강한 API(spawn, terminate, process stop, task mutation)는 `:9877`에 존재하지 않는다.
- 인증 실패의 기본값은 거부다. 헤더가 없으면 403이다.

## 4. 구성 요소

### 4.1 Exposure registry와 `remote.*` RPC (daemon)

```
entry {
  surface_id     GUI: panel UUID / daemon: hex id
  kind           leader | pane
  team_name      kind=leader일 때 필수
  agent_cli      claude | codex | … (pane 프로필 또는 SurfaceInfo.agent_cli)
  keys           safe | none        (기본 safe)
  owner          등록 요청자 (CLI면 로컬 사용자, HTTP면 tailnet login)
  created_at, expires_at            (기본 TTL 24h)
}
```

daemon control socket RPC. 이름은 `watch.*`를 따른다.

| RPC | 입력 | 출력 |
|---|---|---|
| `remote.on` | `{surface_id, kind, team_name?, app_socket?, agent_cli?, title?, cwd?, keys?, ttl_secs?, owner?}` | `{entry, url, listener_enabled}` |
| `remote.off` | `{surface_id}` | `{removed: bool}` |
| `remote.status` | `{surface_id?}` | entry 또는 전체 목록 |
| `remote.list` | `{}` | 만료 entry와 app socket이 사라진 entry를 prune한 뒤 반환(`pruned` 포함). surface 자체의 소멸은 listener가 app의 `not_found`로 관찰해 lazy하게 제거 |

`app_socket`은 `tm-agent remote on`이 pane env의 `TERMMESH_SOCKET_PATH`에서 읽어
넘긴다. listener는 이 경로로만 그 surface에 접근하므로 socket 탐색이 필요 없다.

v1은 in-memory다. daemon 재시작 후에는 `/rc on`을 다시 친다.

### 4.2 `tm-agent remote`

```
tm-agent remote on  [--keys safe|none] [--ttl 12h] [--surface <id>] [--leader]
tm-agent remote off [--surface <id>]
tm-agent remote status
```

- surface는 `TERMMESH_SURFACE_ID`에서, 팀은 `TERMMESH_TEAM`(없으면 `ws-<hex>`
  규칙)에서 읽는다. `--surface`는 term-mesh 밖에서 띄운 셸처럼 env가 없는 경우의
  fallback이다.
- `--leader`를 주거나 현재 pane이 팀 리더 pane으로 확인되면 `kind=leader`, 그 외는
  `kind=pane`이다.
- daemon socket 해석은 `detect_watch_socket` 순서를 재사용한다:
  `TERMMESH_DAEMON_SOCKET` / `TERMMESH_DAEMON_UNIX_PATH` → daemon socket 타입의
  `TERMMESH_SOCKET` → app socket이면 인스턴스 daemon 유도 → 기본 경로. GUI pane은
  첫 단계, daemon pane은 둘째 단계에서 끝난다. `detect_daemon_socket`은
  `TERMMESH_SOCKET`을 보지 않으므로 쓰지 않는다.
- 출력: URL(Phase 1은 `http://127.0.0.1:9877/t/<surface_id>`, Phase 2부터
  `tailscale serve status`에서 읽은 hostname 포함), keys 정책, 만료 시각.

### 4.3 `/rc` 스킬

leader command 관례대로 네 곳을 함께 추가한다.

1. `.claude/commands/rc.md` — 단일 원본.
2. `Resources/CodexPrompts/rc.md` — Codex 네이티브 `/rc`용 압축 shim.
   `$ARGUMENTS`를 받고 Claude command와 모순되지 않는다.
3. `scripts/copy-claude-commands.sh`의 `COMMANDS`/`CODEX_PROMPTS`,
   `Sources/ClaudeCommandInstaller.swift`의 `managedCommandNames`/`managedCodexPromptNames`.
4. `imeSlashCommandAliases()`에 `"/rc": "~/.codex/prompts/rc.md"`.

스킬이 하는 일은 `tm-agent remote on|off|status`를 실행하고 URL과 정책을 보여
주는 것뿐이다. 에이전트는 polling하지 않는다. 리더는 지금처럼 durable request의
wake instruction으로 깨어나고, 일반 pane은 텍스트가 그대로 타이핑된다.

### 4.4 Mobile listener (daemon)

- 모듈 `daemon/term-meshd/src/http_mobile.rs`. `http.rs`와 Router를 공유하지
  않고, dashboard의 spawn/terminate/input/process/task route는 `:9877`에 마운트하지
  않는다.
- 기동 조건과 환경 변수

| 변수 | 기본 | 의미 |
|---|---|---|
| `TERM_MESH_MOBILE_ENABLED` | 없음 | `1`일 때만 기동(opt-in). 앱 Settings 토글이 넘긴다 |
| `TERM_MESH_MOBILE_ADDR` | `127.0.0.1:9877` | loopback이 아니면 기동 거부 + error 로그 |
| `TERM_MESH_MOBILE_AUTH` | `tailscale` | `loopback`은 개발 전용, 기동 시 warn 로그 |
| `TERM_MESH_MOBILE_ALLOWED_LOGINS` | 없음 | 쉼표 구분 tailnet login. 비어 있으면 모두 403 |

- tagged app은 `reload.sh`가 태그별 포트를 넘겨 production과 충돌하지 않게 한다
  (`TERM_MESH_HTTP_DISABLED`를 처리하는 `Sources/TermMeshDaemon.swift:538` 부근).
- 모바일 페이지는 외부 asset 없이 `Resources/mobile/{index.html,app.js,app.css}`
  세 파일을 `include_str!`로 내장하고 `/`, `/t/{surface_id}`, `/app.js`,
  `/app.css`로 낸다. 스크립트와 스타일을 분리한 이유는 CSP를 `'unsafe-inline'`
  없이 `script-src 'self'; style-src 'self'`로 두기 위해서다.

### 4.5 Mobile page

대상 목록 → 대상 화면. 화면은 `format=styled`로 받은 셀 스타일(색·굵게·dim·기울임·
밑줄·반전)과 커서 위치를 그대로 그린다. 그래서 Claude Code가 dim으로 띄우는 제안
문구와 실제 입력이 구분되고 커서가 어디 있는지 보인다. 2초 자동 refresh와 수동
refresh, 사용자가 하단에 있을 때만 자동 scroll. 하단에 composer, 키 버튼 행(Enter, Esc,
y, n, 1–9, ↑, ↓, Tab, Ctrl-C), 리더면 최근 request 상태. 상태 저장은 없다.

## 5. 대상별 경로

| 대상 | 읽기 | 텍스트 | 키 | Phase |
|---|---|---|---|---|
| GUI 리더 pane (relay 리더의 mirror pane 포함) | `team.read leader` | `team.leader.send` (durable, 202) | `surface.send_key` | 1 |
| GUI 일반 pane (단독 세션, 워커) | `surface.read_text` | `surface.send_text` | `surface.send_key` | 1 |
| daemon surface (headless, 로컬) | vt100 `contents()` | `Input` | `Input` (allowlist 바이트) | 3 |
| native agent surface (NDJSON) | transcript 텍스트 (`team.read` native 경로와 동일) | `Input.keys` | 해당 없음 | 1 |
| peer host surface (로컬 mirror 없음) | 원격 host의 같은 listener | 같음 | 같음 | 3 |

GUI pane의 키는 이름을 `surface.send_key {key}`로 넘기고(앱 `sendNamedKey`가
해석), daemon surface는 `key_bytes()`로 바이트를 만들어 `Input`으로 보낸다.
`key_bytes()`는 `term-mesh-cli`에 있으므로 daemon과 공유하려면 `peer-proto`
crate로 옮긴다.

## 6. HTTP API (`:9877`)

공통: 모든 route가 인증을 거친다(정적 페이지 포함). 응답 JSON. 헤더
`Cache-Control: no-store`, `Referrer-Policy: no-referrer`,
`X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none';
script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:;
frame-ancestors 'none'; base-uri 'none'; form-action 'none'`. CORS 없음. POST는
`application/json`만 받고(아니면 415) 본문 64 KiB를 넘으면 413.

| Method | Route | 요청 | 응답 |
|---|---|---|---|
| GET | `/`, `/t/{surface_id}` | | 모바일 페이지 (`/app.js`, `/app.css` 정적 파일) |
| GET | `/api/health` | | `{ok, auth_mode, version}` |
| GET | `/api/targets` | | `{targets: [{surface_id, kind, team_name, agent_cli, title, cwd, source: gui\|headless, keys, owner, created_at, expires_at}], now}`. 호출 시 만료·dead socket entry를 prune |
| GET | `/api/targets/{id}/screen?lines=200` | `lines` 20..1000 | `{surface_id, kind, lines, text, captured_at}` |
| GET | `/api/targets/{id}/screen?lines=200&format=styled` | 위와 같음 | `{format: "styled", columns, rows: [[{t, fg?, bg?, b?, d?, i?, u?, inv?}]], cursor: {row, col}\|null, captured_at}`. 앱 `surface.read_screen_vt`의 VT를 daemon이 `vt100`으로 재생해 셀 스타일을 span으로 묶음. fg/bg는 팔레트 index(0–255) 또는 `#rrggbb`. 페이지는 이 형식을 쓰고 구형 앱이면 plain text로 내려감 |
| POST | `/api/targets/{id}/text` | `{text, request_id?}` | leader: 202 `{request_id, stored, wake_dispatched, request_replayed, claimed_by_leader}` / pane: 200 `{delivered, deduplicated, request_id}` |
| GET | `/api/targets/{id}/requests` | leader만(아니면 409 `not_leader`) | `{count, requests}` (`team.leader.request.list`, 본문 미포함) |
| POST | `/api/targets/{id}/key` | `{key}` | 200 `{key, delivered}` |

키 allowlist(`keys=safe`): `Enter`, `Escape`, `Tab`, `Up`, `Down`, `Left`, `Right`,
`y`, `n`, `1`–`9`, `C-c`(대소문자 정확히 일치). GUI pane 매핑(`http_mobile::gui_key`):
`Enter`/`Escape`/`Tab`/`C-c`/화살표는 앱의 `sendNamedKey`가 아는 이름
(`enter`/`escape`/`tab`/`ctrl-c`/`up`/`down`/`left`/`right`)으로 `surface.send_key`,
`y`/`n`/숫자는 글자 그대로 `surface.send_text`. 화살표를 `send_text`의 CSI 바이트로
보내는 방식은 tagged smoke에서 Claude Code에 닿지 않았다. Claude Code가 kitty keyboard
protocol을 켜므로 Ghostty가 ESC 바이트를 Escape 키로 인코딩해 시퀀스가 깨진다. 그래서
화살표 named key를 앱(`TerminalController+DebugInput.swift` `sendNamedKey`)에 추가했고,
이 앱 버전 이전에는 화살표가 `Unknown key`(502)로 실패한다. daemon surface용 바이트 표 `key_bytes()`
(`daemon/term-mesh-cli/src/peer.rs:2092`)의 `peer-proto` 이동은 Phase 3.
`keys=none`이면 `/key`는 403 `keys_disabled`, allowlist 밖 키는 403 `key_not_allowed`.

멱등성: 리더 텍스트는 durable board가 `request_id`로 중복 실행을 막는다. pane
텍스트는 listener가 `request_id`를 10분간 기억해 재시도 중복 타이핑을 막는다.

| 코드 | 경우 (`error.code`) |
|---|---|
| 400 | 잘못된 JSON, `lines` 범위 밖(`invalid_lines`), 빈 텍스트(`empty_text`), 잘못된 request_id(`invalid_request_id`) |
| 413 / 415 / 422 | 본문 64 KiB 초과 / `application/json` 아님 / 필수 필드 누락 (axum `Json` rejection 그대로) |
| 403 | 신원 없음(`login_required`), allowlist 밖 login(`login_not_allowed`), `keys_disabled`, `key_not_allowed` |
| 404 | 미노출·만료(`not_exposed`), app이 `not_found`를 답해 entry를 제거함(`target_gone`), 없는 route(`no_such_route`) |
| 405 | route는 있으나 method가 다름 |
| 409 | 리더가 아닌 대상의 `/requests`(`not_leader`), daemon 소유 surface(`not_readable`, Phase 3 전까지) |
| 502 | app socket RPC 실패(`app_rpc_failed`) |
| 503 | app socket 연결 불가(`app_unavailable`) |

로그에는 login, surface_id, route, 키 이름만 남긴다. 텍스트 본문과 화면은 남기지
않는다.

## 7. 인증과 노출 경계

- listener는 loopback 전용이고 외부 경로는 Tailscale Serve 하나다.
- `auth=tailscale`(기본): `Tailscale-User-Login`이 `TERM_MESH_MOBILE_ALLOWED_LOGINS`에
  있을 때만 통과. Serve는 tailnet 사용자 요청에만 이 헤더를 붙이고 tagged
  device와 Funnel 트래픽에는 붙이지 않으므로 헤더 부재는 곧 403이다. 헤더 없이
  `curl 127.0.0.1:9877`을 치면 403이 정상이다.
- `auth=loopback`(개발): peer addr가 loopback이면 통과. Phase 1 테스트와 tagged app
  smoke에만 쓴다.
- 같은 사용자 권한의 로컬 프로세스가 헤더를 위조하는 경우는 peer-federation
  threat model과 같이 범위 밖이다.
- dashboard `:9876`과 인증·포트·Router를 공유하지 않는다. dashboard의 password
  체계도 가져오지 않는다.
- 노출은 `remote off`, surface 종료, TTL 만료로 사라진다. `remote.list`가 살아 있는
  surface와 교집합을 내므로 죽은 surface는 목록에 남지 않는다.

## 8. relay (peer host) surface — Phase 3

원격 surface는 두 경우다.

1. Mac 앱이 mirror pane으로 띄우고 있는 원격 surface: mirror pane도 GUI surface라
   Phase 1 경로가 그대로 덮는다. relay 리더는 `sendToLeader` 배선이 있어 durable
   request도 통한다.
2. 로컬에 mirror가 없는 원격 surface: 원격 host의 daemon이 PTY 소유자이므로 registry도
   그쪽에 있다. 원격 pane에서 친 `/rc on`은 주입된 `TERMMESH_SOCKET`으로 그 host
   daemon에 곧바로 등록된다(§2).

권장 경로: host마다 같은 listener를 켜고 Mac listener가 proxy한다.

- 원격 host의 term-meshd도 `TERM_MESH_MOBILE_ENABLED=1`로 자기 listener를
  `127.0.0.1:9877`에 띄운다. 코드는 Mac과 동일하다.
- peer tunnel은 이미 원격 dashboard `9876`을 로컬 `19876+`로 forward한다
  (`PeerSSHTunnel.dashboardRemotePort`, best-effort). 같은 방식으로 원격 `9877`을 두
  번째 forward로 싣고, `peer.host.list`에 `mobile_local_port`를 노출한다.
  현재 tunnel은 dashboard 한 포트만 forward하고 `peer.host.list`는 forward 포트를
  내지 않으므로 이 둘이 Swift 쪽 변경이다.
- Mac listener는 `GET /api/hosts`로 연결된 host를 내고,
  `/api/hosts/{host}/targets…`를 `127.0.0.1:<mobile_local_port>`로 proxy한다.
  원격 listener는 loopback(SSH forward)에서 오므로 `auth=loopback`으로 받고, Mac은
  인증된 login을 `X-TermMesh-Forwarded-Login`으로 넘겨 원격 로그에 남긴다. 키
  allowlist는 Mac에서 먼저 적용한다.

대안: app socket에 `peer.surface.list/snapshot/send_text/send_key` RPC를 추가하고
Mac 앱이 peer 프로토콜로 직접 읽고 쓰는 방식. `SurfaceInfo`에 `remote_control`
플래그와 capability `surface.remote_control.v1`이 필요하다. 원격 listener를 켤 수
없는 host가 생길 때만 고려한다.

폰이 원격 host의 Serve를 직접 열어도 된다(모든 host가 tailnet에 있다). Mac 경유는
목록을 한 곳에 모으는 편의다.

## 9. 단계별 작업, 테스트, 완료 조건

### Phase 1 — localhost

1. daemon registry + `remote.*` RPC. 단위 테스트
   `daemon/term-meshd/tests/remote_registry.rs`: 등록/해제/TTL 만료/stale prune/
   같은 surface 재등록 갱신.
2. `http_mobile.rs` listener. 통합 테스트 `daemon/term-meshd/tests/mobile_http.rs`는
   가짜 app socket(JSON-RPC line server)을 띄워 확인한다: route별 RPC 매핑,
   오류 코드 표, 64 KiB 제한, dashboard route 404/405, 기본 `auth=tailscale`에서
   헤더 없는 요청 403, allowlist 밖 login 403, `keys=none` 403, allowlist 밖 키 403,
   non-loopback bind 거부, 로그에 본문 미기록.
3. (Phase 3로 이동) headless surface 경로와 `key_bytes()`의 `peer-proto` 이동은
   2026-08-25 인터뷰 결정으로 Phase 1에서 제외한다. Phase 1은 GUI pane만 다룬다.
4. `tm-agent remote` + 스킬 네 곳.
5. 모바일 페이지.
6. socket E2E `tests_v2/test_mobile_remote_control.py` (mac-sub 러너, loopback,
   `TERM_MESH_MOBILE_AUTH=loopback`):
   - 팀 생성·리더 attach → 리더 pane env로 `tm-agent remote on` →
     `GET /api/targets`에 `kind=leader` entry
   - `POST /text` 202 → `team.leader.request.list`에 request_id
   - 일반 pane `remote on` → `POST /text` → `surface.read_text`로 수신 확인
   - `POST /key Enter` → 화면 변화 확인
   - `remote off` → 404 ; `keys=none` 재등록 → `/key` 403
   - mac-sub에는 agent CLI가 없으므로 E2E는 shell pane과 repl 리더로 돈다. Claude·Codex
     실제 CLI에서의 `/rc on`·키 반응(화살표 CSI 포함)은 7번의 tagged app 수동 smoke로 확인한다.
7. `(cd daemon && cargo build --release)`, `term-mesh-unit`, Debug build,
   `./scripts/reload.sh --tag mobile-rc`로 tagged app을 띄워(`defaults write
   com.termmesh.app.debug termMeshMobileEnabled -bool true`, `termMeshMobileAuth loopback`)
   Claude pane과 Codex pane에서 `/rc on` → 폰 대신 Mac Safari로 `curl`/페이지 smoke,
   `--cleanup`. 러너는 daemon을 직접 띄우므로 `TERM_MESH_MOBILE_*`를 daemon 실행 줄에
   넣고 `TERMMESH_E2E_MOBILE_ADDR`로 테스트에 전달한다.

완료 조건: 위 테스트 전부 통과. Tailscale 없이 loopback에서 Claude pane과 Codex
pane 각각 `/rc on` → 읽기 → 텍스트 → 키가 동작.

검증 기록 (2026-08-25, `feat/mobile-remote-control` e4cb0a7c):

- 단위·통합: `remote_registry` 12, `mobile_http` 18, `term-mesh-cli` 223+5 통과.
  release build, Debug xcodebuild(번들에 `rc.md` 복사) 통과.
- mac-sub socket E2E `test_mobile_remote_control.py` PASS: shell pane에 `remote on` →
  목록·화면 → 텍스트 타이핑 + `Enter` 실행 → request_id dedupe → `q` 403 →
  `keys=none` 403 → `remote off` 404, repl 리더에 `--leader` → `team.read` 화면 →
  `POST /text` 202 → `/requests`와 app board에서 request 확인.
- tagged app(`--tag mobile-rc`, auth=loopback) 수동 smoke: Claude Code pane에서 텍스트
  타이핑·`Enter`·`Up`/`Down`(입력 히스토리 이동으로 화면 변화 관찰)·`Escape` 전달 확인.
  Codex pane에서 텍스트 타이핑, `/` 팝업 표시, `Escape`로 팝업 닫힘 확인. Codex 팝업의
  선택 강조는 색상만 바뀌어 텍스트 화면으로는 화살표 효과를 관찰할 수 없었다.
- 두 가지를 구현 중에 고쳤다. (1) 화살표를 `send_text`의 CSI 바이트로 보내면 kitty
  keyboard protocol을 켠 Claude Code에 닿지 않아 앱 `sendNamedKey`/`queuedTextForNamedKey`에
  `up/down/left/right` 키 이벤트를 추가했다. (2) `team.leader.request.list`는 리더 pane의
  capability token이 필요해 `tm-agent remote on --leader`가 `TERMMESH_LEADER_REQUEST_TOKEN`을
  registry에 넘기고(직렬화 안 함) listener가 목록 조회에만 전달한다.

### Phase 2 — Tailscale

구현: Settings ▸ Dashboard 아래 "Mobile Remote Control" 카드(토글, 인증 모드, 허용
login, 포트; 바꾸면 daemon 자동 재시작), `tm-agent remote on|status`가
`tailscale serve status --json`을 읽어 `tailnet:` 줄을 덧붙임(Serve가 없으면 실행할
명령을, Funnel이 켜져 있으면 경고를 출력). term-mesh는 tailscale 상태를 바꾸지 않는다.

운영 절차 (Mac에서 한 번):

```bash
# 1. Settings ▸ Dashboard ▸ Mobile Remote Control
#    - 켜기, Authentication = Tailscale identity, Allowed Logins = 자기 tailnet login
#      (`tailscale status --json`의 Self.UserID에 해당하는 User.LoginName, 예: you@example.com)
#    - 포트는 기본 9877. daemon이 자동 재시작된다.
# 2. Serve로 loopback listener를 tailnet HTTPS로 노출 (Funnel은 절대 켜지 않는다)
tailscale serve --bg 9877
tailscale serve status            # https://<mac>.<tailnet>.ts.net → http://127.0.0.1:9877
# 3. pane 안에서
/rc on                            # url: http://127.0.0.1:9877/t/<id>
                                  # tailnet: https://<mac>.<tailnet>.ts.net/t/<id>
# 4. 끄기
tailscale serve reset                 # Serve 설정 전체 제거 (이 Mac은 mobile listener만 서빙)
```

확인 목록:

- 폰(Tailscale 연결, 같은 tailnet 계정)의 Safari에서 `tailnet:` URL을 열어 목록·화면·
  텍스트·키가 동작한다.
- Mac에서 `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9877/api/health`는
  403이다(Serve를 거치지 않아 신원 헤더가 없음). 같은 요청에
  `-H 'Tailscale-User-Login: you@example.com'`을 붙이면 200이다(로컬 위조는 threat
  model 밖).
- allowlist에 없는 login으로 접속하면 403 `login_not_allowed`.
- `tailscale funnel status`에 이 포트가 없어야 한다. `tm-agent remote status`가
  Funnel 경고를 내면 `tailscale funnel off`.

### Phase 3 — relay

§8 권장 경로: 원격 listener, 두 번째 SSH forward, `peer.host.list` 포트 노출,
local daemon headless surface 경로(vt100 `contents()` + `Input`)와 `key_bytes()`의
`peer-proto` 이동,
Mac proxy route, peer E2E(`tests_v2/peer_client.py` 기반, `scripts/peer-ssh-demo.sh`
처럼 localhost SSH로 재현).

## 10. 결정 근거

| 결정 | 이유 |
|---|---|
| surface 단위, 스킬로 opt-in | 리더 전용 모드를 따로 두지 않아도 최소 권한이 되고, 팀이 없는 단독 세션도 같은 경로를 쓴다 |
| 새 프로토콜 없이 app socket RPC 재사용 | `surface.*`와 `team.leader.*`가 이미 있고 focus 정책·off-main 규칙을 지킨다 |
| dashboard와 Router 분리 | dashboard에는 spawn/terminate/process stop이 있어 tailnet 노출 시 공격면이 넓다 |
| 기본 `auth=tailscale`, fail closed | Serve 없이 켠 listener가 우연히 열리지 않게 한다. 개발은 명시적으로 `loopback` |
| Serve 신원 헤더에 의존 | 자체 password/session/revoke를 만들지 않는다. 기기 폐기와 revoke는 Tailscale에서 한다 |
| 키 allowlist 고정 | 키 전송은 설계상 원격 실행이므로 프롬프트 응답에 필요한 최소만 연다 |
| Phase 3는 SSH forward proxy | 원격 dashboard forward와 같은 기법이라 peer 프로토콜 변경이 없고 tunnel 소유자가 앱 하나로 유지된다 |
| registry in-memory | 필요성이 확인되기 전에는 영속화하지 않는다 |

## 11. 열린 결정

- registry 영속화(daemon 재시작 후 유지) 여부.
- 구조화 transcript v2: daemon이 이미 `~/.claude/projects/*.jsonl`과
  `~/.codex/sessions/rollout-*.jsonl`을 pane별로 매핑하므로(`tokens.rs:405`,
  `codex_tokens.rs:129`) 같은 파서를 메시지 단위로 확장해 채팅 뷰를 만든다.
- 푸시 알림. 현재 불필요.

## 부록. 8/21 계획과의 차이

| 항목 | 8/21 | v2 |
|---|---|---|
| 대상 단위 | team leader | surface(pane). 리더는 그중 한 종류 |
| 켜는 방법 | 설정에서 listener 기동 | `/rc on` 스킬 → `tm-agent remote` → registry |
| 쓰기 | `team.leader.send`만 | + `surface.send_text` + 키 allowlist |
| 읽기 | `team.read leader` | + `surface.read_text` + daemon vt100 `contents()` |
| relay | 미정 | Phase 1은 mirror pane, Phase 3은 SSH forward proxy |
| 인증 | Tailscale 전제 | `tailscale`(기본) / `loopback`(개발) 모드 분리 |
| 테스트 | tailnet 실기기 포함 | Phase 1은 localhost만 |

유지: `127.0.0.1:9877`, dashboard 분리, durable request 재사용, 2초 polling, 보안
헤더, 본문 미로깅, 오류 코드 정규화.
