# 상세설계 — term-mesh MCP 서버

작성일: 2026-07-07
상태: Design Draft (구현 전)
상위 문서: `docs/strategy-differentiation-roadmap.md` §E-1
관련 코드: `Sources/TerminalController.swift` (v2 dispatch), `Sources/SocketControlSettings.swift`, `daemon/term-mesh-cli/src/` (rpc/socket 해석), `skills/term-mesh/`, `skills/term-mesh-browser/`

---

## 1. 목표

기존 v2 소켓 API를 **MCP(Model Context Protocol) 서버**로 노출해, 모든 MCP 클라이언트(Claude Code, Claude Desktop, 타 에이전트 프레임워크)가 term-mesh를 도구로 사용할 수 있게 한다.

가치:
- 에이전트가 term-mesh 자체를 조작하는 자율 루프 개방 — 팀 생성, pane 제어, **브라우저로 자기 결과물 검증**, 알림 발행.
- term-mesh 미탑재 컨텍스트(Claude Desktop 대화 등)에서도 함대 상태 조회·태스크 투입 가능.
- skills 문서(`skills/term-mesh/`, `skills/term-mesh-browser/`)로만 존재하던 계약이 기계가 읽는 스키마로 승격.

비목표: MCP resources/prompts의 전면 활용(v1은 tools 중심 + 최소 resources), 원격(네트워크) MCP 서빙(v1은 로컬 stdio).

## 2. 현재 상태 (As-Is)

- **MCP 서버는 존재하지 않는다.** 코드베이스의 `mcp` 언급은 에이전트 서브프로세스의 MCP 서버 reaping 주석뿐 (`daemon/term-meshd/src/headless/mod.rs:659,940`).
- **소켓 프로토콜이 MCP에 거의 1:1로 맞는다**: newline-delimited JSON, 요청 `{id, method, params}` → 응답 `{id, ok, result|error{code,message,data}}` (`TerminalController.swift:713-734`, `v2Ok/v2Error` `:1590-1615`). MCP `tools/call` → 소켓 요청 → `{ok:false}` → MCP tool error로 기계적 변환 가능.
- **v2 커맨드 카탈로그** (`TerminalController.swift:761-1144`): `system.*, auth.login, window.*(5), workspace.*(14), surface.*(17), pane.*(9), team.*(30+), notification.*(5), app.*, browser.*(~90)`.
- **인증 모델** (`Sources/SocketControlSettings.swift:5`): `off | termMeshOnly(기본) | automation | password | allowAll(1시간 자동 만료)`. 소켓 파일 0600. `termMeshOnly`는 **term-mesh 터미널 후손 프로세스만 허용**하는 ancestry 검사.
- **소켓 해석**: 앱 컨트롤 소켓은 인스턴스별로 다름(prod/STAGING/tag, `SocketControlSettings.defaultSocketPath` `:286-315`). tm-agent의 우선순위 해석기(`detect_socket`, `tm_agent.rs:2779`): `TERMMESH_SOCKET` → `TERMMESH_SOCKET_PATH` → `/tmp/term-mesh-last-socket-path` → glob.
- **focus 정책**: focus-변형 커맨드는 명시적 화이트리스트(`focusIntentV2Methods`, `SocketControlSettings.swift:63`)로 게이트.

## 3. 형태 결정

### 3.1 바이너리: `term-mesh-mcp` (Rust, stdio)

- **위치**: `daemon/term-mesh-cli/` workspace에 세 번째 바이너리로 추가 (`src/mcp_server.rs`). 근거: 소켓 해석기(`detect_socket`)·RPC 클라이언트(`rpc_call_timeout`, `tm_agent.rs:2855`)·타임아웃/에러 규약을 그대로 재사용. 앱 번들 `Resources/bin/`에 동봉하고 tm-agent와 함께 brew symlink.
- **전송**: v1은 stdio 전용 (Claude Code/Desktop의 표준 로컬 서버 형태). HTTP/SSE 전송은 원격 뷰어 로드맵(§D-3)과 함께 후속.
- **MCP 구현**: 공식 Rust SDK(rmcp) 사용. 프로토콜 버전 협상·capabilities는 SDK에 위임.
- **등록 UX**: `term-mesh-mcp install [--client claude-code|claude-desktop|codex]` 서브커맨드가 각 클라이언트 설정에 서버 항목을 추가(diff 제시 → 확인). 온보딩 마법사(로드맵 §A-2)의 "Install Claude Code integration" 스텝과 동일 패턴.

```json
{ "mcpServers": { "term-mesh": { "command": "term-mesh-mcp", "args": [] } } }
```

### 3.2 대상 소켓과 멀티 인스턴스

- 기본: `detect_socket` 우선순위 그대로. 플래그 `--socket <path>` / env `TERMMESH_SOCKET` override.
- MCP 클라이언트가 term-mesh pane **안**에서 떴다면(`TERMMESH_SOCKET_PATH` 상속) 자동으로 올바른 인스턴스에 붙는다 — 0.142.0 멀티 인스턴스 라우팅 수정과 동일 원칙.
- 데몬 소켓(`term-meshd.sock`)은 v1에서 노출하지 않는다 — 앱 소켓이 유일한 공개 표면 (worktree/monitor가 필요해지면 별도 tool로 후속).

## 4. Tool 설계 — 1:1 노출이 아니라 큐레이션

~170개 메서드를 그대로 노출하면 tool 목록이 컨텍스트를 오염시키고 클라이언트 UX가 무너진다. **동사 통합(consolidation) 전략**으로 12~16개 tool로 압축한다. skills 문서가 이미 검증한 워크플로우(snapshot → ref → act → wait)를 tool 경계로 삼는다.

### 4.1 Tool 카탈로그 (v1)

| Tool | 매핑 | 비고 |
|------|------|------|
| `tm_identify` | `system.identify` + `system.capabilities` | 토폴로지 진입점. 호출 컨텍스트(현재 workspace/pane) 반환 |
| `tm_list` | `window.list`/`workspace.list`/`pane.list`/`surface.list` | `scope` 파라미터로 통합. short ref(`surface:N`) 반환 |
| `tm_workspace` | `workspace.create/select/rename/close/move_to_window` | `action` 파라미터. `close`는 destructive 플래그(§5) |
| `tm_pane` | `surface.split`, `pane.focus/resize/swap/break/join`, `surface.move/close` | 레이아웃 조작 통합 |
| `tm_terminal_send` | `surface.send_text`/`surface.send_key` | 텍스트/키 입력 |
| `tm_terminal_read` | `surface.read_text` | 스크롤백 읽기 (에이전트 관찰 프리미티브) |
| `tm_browser_open` | `browser.open_split`/`navigate`/`tab.*` | 브라우저 세션 시작·이동 |
| `tm_browser_snapshot` | `browser.snapshot` | interactive ref(`e1,e2…`) 포함 — act의 전제 |
| `tm_browser_act` | `browser.click/fill/type/press/select/check/hover/scroll…` | `action`+`ref` 파라미터로 상호작용 통합 |
| `tm_browser_wait` | `browser.wait` | selector/text/url/load-state/function 모드 |
| `tm_browser_eval` | `browser.eval` | JS 평가 (§5 게이트) |
| `tm_browser_screenshot` | `browser.screenshot` | 이미지 콘텐츠 반환 (MCP image content) |
| `tm_fleet_status` | `team.list`/`team.status`/`team.task.list` (Mission Control 설계의 `fleet.state` 출시 후 그것으로 교체) | 읽기 전용 함대 조회 |
| `tm_fleet_task` | `team.task.create/update/start/…` + `team.send/delegate 경로` | task 투입·전이. **주의**: term-mesh pane 안의 리더 에이전트는 CLAUDE.md OMC override에 따라 계속 `tm-agent`를 쓴다 — 이 tool은 **외부** MCP 클라이언트용 |
| `tm_notify` | `notification.create_for_target` | 사용자 어텐션 요청 |
| `tm_call` | 임의 `{method, params}` passthrough | escape hatch. 기본 비활성 — `--enable-raw-call`로만 활성, allowlist 검사 통과분만 |

- 각 tool의 inputSchema는 소켓 params를 그대로 옮기되 short ref 규약(`workspace:N`/`surface:N`, `skills/term-mesh/SKILL.md`의 handle 모델)을 스키마 description에 명시.
- tool description은 skills 문서에서 발췌해 생성 — **skills 문서를 단일 소스로 유지**하고, 빌드 시 `scripts/`에서 카탈로그 JSON(`tools-manifest.json`)을 생성해 바이너리에 embed. 소켓 API가 늘 때 manifest만 갱신하면 된다.
- annotations: MCP tool hints 사용 — `readOnlyHint`(`tm_identify/tm_list/tm_terminal_read/tm_browser_snapshot/tm_fleet_status`), `destructiveHint`(`tm_workspace(close)/tm_pane(close)`), `openWorldHint`(browser 계열).

### 4.2 Resources (v1 최소)

- `term-mesh://fleet` — `tm_fleet_status` 결과의 리소스 뷰 (클라이언트가 컨텍스트로 pin 가능).
- `term-mesh://results/<team>/<file>` — `~/.term-mesh/results/` 읽기 전용 브릿지 (FULL_REPORT 경로를 MCP 클라이언트가 직접 읽도록).

## 5. 보안·권한 모델

MCP 서버는 소켓 인증을 **우회하는 문**이 될 수 있으므로 가장 신중히 설계한다.

1. **소켓 모드와의 관계**: Claude Desktop이 띄운 `term-mesh-mcp`는 term-mesh 터미널의 후손이 아니므로 기본 모드(`termMeshOnly`)에서 **연결이 거부된다 — 이것은 버그가 아니라 기본 안전선**. install 서브커맨드가 이를 감지해 안내한다: "Settings → Socket Control에서 `automation` 모드 활성화 필요(같은 macOS 사용자의 로컬 프로세스만 허용) 또는 password 모드 + `TERMMESH_SOCKET_PASSWORD` 설정". `allowAll` 안내는 하지 않는다.
2. **2단 레이어링**: 소켓 모드(누가 연결하나) 위에 MCP 서버 자체의 tool 게이트(무엇을 하나)를 얹는다:
   - 기본 프로파일 `standard`: 카탈로그의 destructive 액션(`workspace.close`, `pane close`, team destroy 계열) **제외**, `tm_call` 비활성, `tm_browser_eval` 활성.
   - `--profile readonly`: read 계열만.
   - `--profile full` + `--enable-raw-call`: 전부. 명시적 opt-in.
   - 프로파일은 서버 기동 인자로 고정 — 대화 중 에이전트가 스스로 승격 불가.
3. **focus 정책 준수**: focus-변형 메서드는 소켓 레벨 게이트(`focusIntentV2Methods`)가 이미 방어하지만, MCP tool description에도 "포커스를 훔치지 않는 기본값"을 명시하고 `tm_pane`의 focus 액션에 `intent: user_requested` 파라미터를 요구한다.
4. **프롬프트 주입 표면**: `tm_terminal_read`/`tm_browser_snapshot`의 반환값은 신뢰할 수 없는 콘텐츠(웹페이지, 터미널 출력)다. tool 결과에 MCP 표준은 없으므로, 반환 텍스트 앞에 고정 헤더(`[untrusted terminal/page content]`)를 붙여 클라이언트 모델에 힌트를 준다.
5. **감사**: 모든 tool 호출을 `~/.term-mesh/audit/mcp-<date>.jsonl`에 append (로드맵 §C-2 감사 로그의 첫 번째 고객).

## 6. 에러·시맨틱 매핑

| 소켓 | MCP |
|------|-----|
| `{ok:true, result}` | tool result content (JSON은 text로 직렬화, 스크린샷은 image content) |
| `{ok:false, error:{code,message}}` | tool result `isError:true` + `code: message` 텍스트 (프로토콜 에러로 던지지 않는다 — 모델이 읽고 복구해야 하므로) |
| `not_supported` (WKWebView 갭: viewport/offline/trace/network route/screencast/raw input, `skills/term-mesh-browser/SKILL.md`) | 동일 — tool description에 갭 목록 명시해 시도 자체를 줄임 |
| 소켓 연결 실패/타임아웃(6s, `TERMMESH_RPC_TIMEOUT`) | `isError:true` + "term-mesh not running / socket mode 확인" 안내 |
| truncation (1500자 reply 규약) | `tm_fleet_status`가 `resultPath`를 함께 반환 → 클라이언트는 `term-mesh://results/...` 리소스로 전문 조회 |

## 7. 변경 지점 목록

| 컴포넌트 | 변경 | 크기 |
|----------|------|------|
| `daemon/term-mesh-cli/src/mcp_server.rs` (신규) | rmcp stdio 서버, tool 라우터, 프로파일 게이트, install 서브커맨드 | L |
| `daemon/term-mesh-cli/Cargo.toml` | rmcp 의존성, `[[bin]] term-mesh-mcp` | S |
| `scripts/` | tools-manifest 생성 스크립트 (skills 문서 → JSON) | S |
| 앱 번들/brew | `Resources/bin/term-mesh-mcp` 동봉 + symlink | S |
| `Sources/` (앱) | **변경 없음** (v1은 순수 어댑터; `fleet.state` 출시 시 tool 매핑만 교체) | — |
| `skills/term-mesh-mcp/` (신규) | 사용자용 스킬 문서: 설치·프로파일·트러블슈팅 | S |
| 문서 | README Features에 MCP 섹션, docs-site 가이드 | S |

앱 무변경이 핵심 설계 제약이다 — 소켓 API가 이미 계약이므로 어댑터는 독립 배포·독립 버전업 가능.

## 8. 테스트 전략

- **Rust 단위**: tool→method 매핑 전수, 프로파일 게이트(standard에서 destructive 거부), 에러 변환, manifest 로드.
- **통합 (VM, tests_v2 확장)**: 실제 앱 소켓에 대해 MCP 클라이언트 하네스(Python `mcp` SDK)로:
  1. initialize → tools/list가 프로파일별 올바른 부분집합 반환.
  2. `tm_identify` → `tm_list(workspaces)` → `tm_workspace(create)` → `tm_terminal_send/read` 왕복.
  3. 브라우저 루프: open → snapshot(ref) → act(click) → wait → screenshot(image content 검증).
  4. `termMeshOnly` 모드에서 연결 거부 + 안내 메시지, `automation` 모드에서 성공.
  5. `tm_call` 비활성 기본값 검증.
- **컨트랙트 테스트**: tools-manifest의 모든 method가 실제 v2 dispatch에 존재하는지(`system.capabilities` 대조) — 소켓 API 변경 시 manifest 누락을 CI에서 잡는다.

## 9. 단계별 출시

| 단계 | 범위 |
|------|------|
| **P1** | stdio 서버 + 카탈로그 중 topology/terminal/notification/fleet-read (browser 제외) + install 커맨드 + readonly/standard 프로파일 |
| **P2** | browser tool 5종 + screenshot image content + resources 브릿지 + 감사 로그 |
| **P3** | `tm_fleet_task`(쓰기 계열) + full 프로파일 + `fleet.state` 교체 + docs-site 가이드 + (검토) HTTP 전송 |

browser를 P2로 미루는 근거: 가장 가치가 크지만 tool 수·주입 표면·이미지 콘텐츠 처리 등 리스크도 가장 크다. P1로 어댑터 골격과 보안 모델을 먼저 굳힌다.

## 10. 미해결 질문

1. **Swift 앱에 내장 vs 별도 바이너리** — 본 설계는 별도 바이너리(앱 무변경·독립 배포)를 선택했다. 반론: 앱 내장이면 소켓 인증을 우회한 직접 호출이 가능해 `automation` 모드 요구가 사라진다. v2에서 앱이 자체 MCP endpoint(런치 시 등록되는 stdio 브로커)를 제공하는 방안 재검토.
2. tool 통합 입도 — `tm_browser_act`처럼 동사를 합치면 tool 수는 줄지만 inputSchema가 복잡해진다. P1 출시 후 실제 클라이언트(Claude Code)의 오호출률로 조정.
3. term-mesh pane **내부** 에이전트가 이 MCP 서버를 쓰는 것을 허용할지 — CLAUDE.md OMC override(팀 작업은 `tm-agent` 강제)와의 충돌 방지 규칙을 skills 문서에 어떻게 기술할지. 초안: MCP tool description에 "TERMMESH_SOCKET env가 있으면 팀 작업은 tm-agent 사용" 명시.
