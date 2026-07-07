# 상세설계 — Mission Control 뷰 + Diff 리뷰·승인 큐

작성일: 2026-07-07
상태: Design Draft (구현 전)
상위 문서: `docs/strategy-differentiation-roadmap.md` §B-2, §B-3
관련 코드: `Resources/dashboard/index.html`, `Sources/DashboardController.swift`, `Sources/TeamOrchestrator.swift`, `Sources/TerminalController.swift`, `daemon/term-meshd/src/http.rs`, `daemon/term-meshd/src/watch_controller.rs`, `daemon/term-mesh-cli/src/tm_agent.rs`

---

## 1. 목표

운영자 질문 두 개에 앱 안에서 답한다:

1. **"지금 함대가 뭘 하고 있나?"** → Mission Control: 에이전트 × 상태 매트릭스, task 칸반, heartbeat, watch verdict 타임라인을 한 화면에.
2. **"뭘 승인해야 하나?"** → 승인 큐: worktree 에이전트가 `review_ready`로 보고하면 diff 요약 카드가 큐에 적재되고, Approve = `finish-worktree --to parent` 원클릭.

## 2. 현재 상태 (As-Is) — 생각보다 많이 있다

조사 결과 Mission Control은 **신규 화면이 아니라 기존 대시보드의 보강**이다.

이미 존재:
- 운영 대시보드는 단일 파일 `Resources/dashboard/index.html`(~3800줄, Chart.js), 두 경로로 렌더 — 앱 내 WKWebView(`DashboardController.swift:134`, 2s `evaluateJavaScript` 푸시 `:613-731`) + 데몬 HTTP `:9876`(`http.rs:249`, 2s fetch 폴링 `:1261`).
- 프리셋(탭) 시스템: `overview | teamOps | devOps | cost` (`DashboardController.swift:8-10`, JS `switchPreset()`).
- **팀 그리드**(`#team-overview-card`), **칸반**(`#team-tasks-card`, pending/running/done 3열), **Gantt 타임라인**(`#agent-timeline-card`), **attention 카드**(`#team-attention-card`), 알림 벨(`#notification-badge`)까지 이미 렌더됨.
- `team.status`가 이미 운반하는 필드: `agent_state, active_task_id/title/status, active_task_is_stale, heartbeat_age_seconds, last_heartbeat_summary, heartbeat_is_stale, panel_id, workspace_id, completed_task_count, worktree_branch/path` (`TeamOrchestrator.swift:3821-3851`).
- HTTP `/api/team`은 데몬이 앱 소켓을 live-proxy(`fetch_live_team_state`, `http.rs:346-408`)하며 멀티 인스턴스 소켓 스캔까지 함.
- 데몬 소켓에 push 스트림 존재: `events.subscribe` NDJSON, kinds = `task_status | reply | heartbeat_stale | agent_usage_tick` (`socket.rs:110-145,392-513`). 단 앱은 `agent_usage_tick`만 구독(`TermMeshDaemon.swift:935`).

공백 (이번 설계가 채울 것):
1. **`waiting_input`이 일급 상태가 아님** — `agentRuntimeState`(`TeamOrchestrator.swift:5416-5445`)는 task 파생 상태만 있고, "입력 대기"는 세션 레벨 unread 알림 파생(`DashboardController.swift:235`)으로만 존재.
2. **heartbeat 위젯 없음** — 데이터는 payload에 있으나 렌더하는 카드가 없음.
3. **watch verdict 히스토리 API 없음** — `.xm/watch/board.jsonl`(`watch_controller.rs:163-203`)은 영속되지만 `watch.status`는 `drift_count` 집계만 반환(`socket.rs:2356-2431`), 행 자체를 주는 소켓/HTTP 메서드 없음.
4. **승인 큐의 3대 부재**: diff 생산자 없음(앱에는 branch+dirty count만, `Sources/WorkspaceModels.swift:87`), approve RPC 없음(`finish-worktree`는 CLI 전용, `tm_agent.rs:8673`), 큐 UI 없음(가장 가까운 훅은 inbox의 `review_ready` priority 2 항목, `TeamOrchestrator.swift:5145-5177`).
5. **대시보드로의 push 없음** — 전부 2s 폴링.

## 3. 설계 A — 상태 모델 통합 (`agent_state` 일급화)

세 개의 독립 상태 소스(task 파생 / 알림 파생 / AutoReplyDetector)를 하나의 enum으로 통합한다.

```
idle | working | waiting_input | blocked | review_ready | error | parked | stale
```

**도출 규칙** (`TeamOrchestrator.agentRuntimeState` 확장, 우선순위 순):

| 순위 | 조건 | 상태 |
|------|------|------|
| 1 | `isAgentParked` | `parked` |
| 2 | 활성 task `blocked` | `blocked` |
| 3 | 활성 task `review_ready` | `review_ready` |
| 4 | 활성 task `failed` | `error` |
| 5 | **agent pane의 unread 알림 존재** (신규 배선, 아래) | `waiting_input` |
| 6 | 활성 task `in_progress` (+ stale이면 `stale`) | `working` |
| 7 | 그 외 | `idle` |

**waiting_input 배선**: `TerminalNotificationStore`는 `tabId`/`surfaceId` 키(`TerminalNotificationStore.swift:69-78`)이고 팀은 `panelId`/`workspaceId`를 안다(`teamStatus()` `:3841`). `TeamOrchestrator`에 `agentHasUnreadNotification(agent:)`을 추가해 `AgentMember.workspaceId → tabId` 매핑으로 `unreadCount(forTabId:)`를 조회한다. 보조 신호로 `AutoReplyDetector`(`Sources/AutoReplyDetector.swift:41-112`)의 "출력 정지 + Standard Header 미완성" 패턴을 후속 단계에서 추가할 수 있으나, P1은 알림 파생만으로 시작한다(오탐이 적고 배선이 싸다).

이 통합 상태는 기존 `agent_state` 필드에 **하위호환으로 덮어쓴다** (기존 소비자는 문자열을 표시만 하므로 값 추가는 안전; `assigned_stale`→`stale`로 정리하는 것만 CHANGELOG에 명시).

## 4. 설계 B — 집계 API: `fleet.state`

Mission Control 한 화면이 폴링 1회로 그려지도록 v2 집계 메서드를 추가한다.

- **등록 위치**: `TerminalController.processV2Command`의 v2 switch (`TerminalController.swift:760-1231`) — `team.` prefix가 아니므로 일반 경로에 `fleet.state` 케이스 추가. 구현은 `TeamOrchestrator.daemonPayload()`(`:3772-3798`, 이미 `{teams, tasks, attention, instance}`를 합성)를 확장한 `fleetState()`.
- **응답 스키마**:

```json
{
  "schema": 1,
  "instance": { "socket": "…", "bundle": "…" },
  "teams": [ { "…team.list 필드…", "agents": [ { "…agent_state 등 기존 필드…" } ] } ],
  "tasks":  [ { "…taskDictionary…" } ],
  "attention": [ { "…inboxItems 항목…" } ],
  "approvals": [ { "…§6 승인 카드…" } ],
  "watch": { "<team>": { "…watch.status 요약…", "recent": [ "…board.jsonl 최근 N행…" ] } }
}
```

- **HTTP 미러**: `http.rs`에 `GET /api/fleet` 추가 — `/api/team`과 동일한 live-proxy 패턴(`fetch_team_payload_from_socket` `:410-478` 일반화)으로 `fleet.state`를 호출. 멀티 인스턴스 소켓 스캔(`candidate_team_socket_paths` `:500`)도 그대로 재사용.
- **watch 히스토리 메서드 (데몬)**: `watch.board { team_id, limit=50 }` — `board.jsonl`을 tail해 `BoardFinding` 행(`{ts, agent, drift_type, severity, finding, spec_clause, check_id}`, `watch_controller.rs:27-37`)을 반환. `board_drift_count`(`socket.rs:31-42`)와 같은 파일을 읽는다. `fleet.state`의 `watch.recent`는 이 메서드를 데몬에 위임해 채운다.

## 5. 설계 C — Mission Control 프리셋

신규 프리셋 `mission`을 추가한다 (기존 `teamOps`를 대체하지 않고 병존; 안정화 후 `teamOps` 흡수 여부 결정).

**레이아웃 (카드 구성)**

```
┌────────────────────────────────────────────────────────┐
│ 요약 타일: agents by state (working 3 · waiting 1 · …) │
├──────────────────────────┬─────────────────────────────┤
│ Agent × State 매트릭스    │ 승인 큐 (§6)                 │
│ (행=agent, 셀=상태 칩 +   │ diff 카드 스택               │
│  active task + heartbeat)│                             │
├──────────────────────────┼─────────────────────────────┤
│ 칸반 (기존 #team-tasks)   │ Watch verdict 타임라인 (신규)│
├──────────────────────────┴─────────────────────────────┤
│ Gantt 타임라인 (기존)                                    │
└────────────────────────────────────────────────────────┘
```

- **매트릭스 카드 (신규)**: 행마다 `agent 이름 · 상태 칩(색상 = 상태) · active task 제목 · heartbeat 요약("3m ago — parsing socket.rs")`. 데이터는 전부 `fleet.state.teams[].agents[]`에 이미 있음.
- **heartbeat**: 별도 카드가 아니라 매트릭스 행 내 인라인 + stale이면 주황 배지 (`heartbeat_is_stale` 필드 활용).
- **watch 타임라인 (신규)**: `watch.recent` 행을 세로 타임라인으로, severity 색상, 클릭 시 finding 전문 팝오버.
- **딥링크 (핵심 UX)**: 매트릭스 셀/칸반 카드 클릭 → 신규 WKWebView 메시지 핸들러 `focusAgentPane {team, agent}` (`DashboardMessageHandler.userContentController` `:860-921`에 추가) → `panel_id/workspace_id` 해석 → 기존 `tabManager.focusTabFromNotification(tabId, surfaceId:)`(`AppDelegate+Notifications.swift:296-336`의 점프 경로) 호출. 사용자가 직접 클릭한 것이므로 socket focus policy 위반 아님. HTTP(브라우저) 경로에서는 딥링크 버튼을 숨긴다(원격 브라우저가 로컬 포커스를 못 바꾸는 게 맞다).
- **구현 형태**: `index.html`에 `data-presets="mission"` 카드 3개 추가 + `updateFleet(fleet)` JS 함수 1개. WKWebView 경로는 `fetchAndPush()`가 `fleet.state`를 호출해 push, HTTP 경로는 `HTTP_POLL_SCRIPT`에 `/api/fleet` 폴링 추가.

**전송 계층 — 폴링 유지, push는 후속.** 2s 폴링은 현재 규모(수십 agent)에서 충분하다. 후속 단계에서:
1. 데몬 `events.subscribe` kinds에 `agent_state_change`, `approval_enqueued` 추가 (`DaemonEvent` enum, `socket.rs:110-145`).
2. 앱: `TermMeshDaemon.startEventSubscription`(`:916-1010`)의 구독 kinds 확장 → 수신 시 `DashboardController`가 즉시 1회 push (폴링 주기와 무관한 반응성).
3. HTTP: axum에 SSE `GET /api/events` 추가.
이 3개는 전부 additive이므로 프리셋 출시를 막지 않는다.

## 6. 설계 D — Diff 리뷰·승인 큐

### 6.1 큐의 정의 — 새 저장소를 만들지 않는다

**승인 큐 = `status == review_ready`인 task의 파생 뷰.** 이미 `inboxItems`가 review_ready를 priority 2로 합성하고 있고(`TeamOrchestrator.swift:5145-5177`), task board 영속화(Restore Fleet 설계 Layer 2)가 큐의 내구성을 공짜로 제공한다. 신규 상태 머신·신규 스토어 없음.

카드 2종:
- **worktree 카드** (`worktreePath != nil`): diff 요약 + Approve/Reject/Delegate 버튼.
- **review-only 카드** (worktree 없음): `reviewSummary` + FULL_REPORT 링크 + Done/Reject 버튼 (approve 대신 `team.task.done`).

### 6.2 Diff 생산자 — 데몬 git2 RPC (신규)

앱에는 diff 프리미티브가 없고(branch+dirty count뿐), 데몬에는 git2 기반 `worktree.rs`가 이미 있다(`status()` `:397`가 statuses + `graph_ahead_behind` 사용). 여기에 추가:

- **RPC**: `worktree.diff_summary { path, base_ref? }` (base 기본값: worktree 브랜치의 merge-base with parent — task capsule의 `worktree_parent` 필드를 앱이 넘겨준다)
- **응답**:

```json
{
  "base": "develop", "branch": "tm/my-team/t42",
  "ahead": 3, "behind": 0, "dirty": false,
  "files": [ { "path": "Sources/Foo.swift", "kind": "modified", "add": 42, "del": 7 } ],
  "total_add": 120, "total_del": 15, "file_count": 4
}
```

- git-kit worktree도 결국 표준 git worktree이므로 git2로 열 수 있다 (`worktree.rs:84-106`의 main-repo 해석 로직 재사용).
- **패치 본문은 v1에서 반환하지 않는다.** 카드에는 파일 목록 + 통계만; "전체 diff 보기"는 해당 pane에서 `git diff`를 여는 딥링크(또는 `git-kit diff --digest` 출력 파일 링크)로 대체. 소켓으로 대형 패치를 나르는 것은 truncation 프로토콜(1500자)과 충돌한다.
- **캐싱**: `review_ready` 전이 시점에 1회 계산해 task에 `diffSummary` JSON을 저장(아래 6.3), 카드 렌더는 저장값 사용. Approve 직전에 재계산해 stale 여부(`dirty==true` 또는 file_count 변화)를 검증한다.

### 6.3 상태 전이 훅

`team.task.review` 핸들러(`TerminalController.swift:4662`)에 후처리 추가:
1. task에 `worktreePath`가 있으면 데몬 `worktree.diff_summary` 호출 → `TeamTask`에 신규 필드 `diffSummary: String?`(JSON), `diffComputedAt: Date?` 저장.
2. `TerminalNotificationStore.addNotification` — 제목 "승인 대기: <task title>", 딥링크 userInfo에 `{team, taskId}` → 클릭 시 Mission Control 열고 해당 카드 하이라이트.
3. (push 후속 단계) `approval_enqueued` 이벤트 방출.

### 6.4 Approve/Reject RPC — finish-worktree의 단일 구현화

현재 `finish-worktree`는 CLI 전용 조합(`team.task.get` + `git-kit wt finish` + `team.task.update`, `tm_agent.rs:8673-8739`)이다. GUI 버튼을 위해 이를 RPC로 승격하되 **구현을 두 벌 만들지 않는다**:

- **신규 v2 RPC**: `team.task.approve { task_id, push?: bool, cleanup?: bool }`, `team.task.reject { task_id, reason, reassign_to? }`
- **`approve` 구현 (Swift)**: `run_task_finish_worktree`와 동일 계약을 Swift에서 수행 —
  1. 동일 lock 파일 프로토콜 준수 (`/tmp/term-mesh-worktree-locks/<team>-<task>.lock`, `tm_agent.rs:8578`과 같은 경로·의미 — CLI와 GUI가 같은 task를 동시에 finish하지 못하게 하는 상호배제).
  2. stale 검증: diff 재계산, `dirty==true`면 실패 반환("worktree에 커밋되지 않은 변경 — 에이전트에게 커밋 지시 필요").
  3. `git-kit wt finish --to parent --json [--cleanup] [--push]`를 worktree cwd에서 subprocess 실행 (`GK_AGENT=1`; 머지 의미론은 계속 git-kit 단일 소유).
  4. 성공 → `team.task.done` 경로로 `completed` 전이 + `worktree_finished_at/mode/removed` 기록 (CLI와 동일 필드, `:8725-8739`).
  5. 실패 → task `blocked` + `blockedReason`에 git-kit 에러 (CLI와 동일 정책 `:8715`).
- **후속**: `tm-agent task finish-worktree`가 이 RPC를 호출하도록 마이그레이션 → 구현 단일화. v1에서는 병존 허용(계약이 같으므로).
- **`reject` 구현**: `reassign_to`가 있으면 `reassignTask` + task capsule 재전송(기존 `dispatchTaskToAssignee` 경로), 없으면 status `assigned`로 되돌리고 reason을 agent에게 `team.send`로 통지. worktree는 보존(재작업 장소).
- **Delegate-to-reviewer 버튼**: 신규 RPC 없이 `team.task.reassign(reviewer)` + capsule 재전송으로 구성.

### 6.5 실행 주체 주의사항

- `git-kit` subprocess 실행은 socket command threading policy에 따라 **off-main**에서 수행하고 완료 시 board 변형만 main으로 스케줄한다.
- 앱 환경의 PATH에 `git-kit`이 없을 수 있음(0.141.0의 launchd PATH 이슈와 동일) → 데몬의 사용자 bin 경로 복구 로직과 같은 해석기를 Swift에도 적용, 미발견 시 카드에 "git-kit not found" 에러와 설치 안내.

## 7. 변경 지점 목록

| 컴포넌트 | 변경 | 크기 |
|----------|------|------|
| `Sources/TeamOrchestrator.swift` | `agent_state` 통합 도출, `fleetState()`, review 전이 후처리 | M |
| `Sources/TerminalController.swift` | v2 `fleet.state`, `team.task.approve/reject` 핸들러 | M |
| `daemon/term-meshd/src/worktree.rs` | `diff_summary` (git2) | M |
| `daemon/term-meshd/src/socket.rs` | `worktree.diff_summary`, `watch.board` 디스패치 | S |
| `daemon/term-meshd/src/http.rs` | `GET /api/fleet` live-proxy (+후속 SSE) | S |
| `Resources/dashboard/index.html` | `mission` 프리셋 카드 3종 + `updateFleet()` + 승인 카드 액션 | L |
| `Sources/DashboardController.swift` | fleet push, `focusAgentPane`/`approveTask` 메시지 핸들러 | M |
| `Sources/TerminalNotificationStore` 경로 | 승인 딥링크 알림 | S |
| `daemon/term-mesh-cli/src/tm_agent.rs` | (후속) finish-worktree → RPC 위임 | S |

## 8. 테스트 전략

- **Rust 단위**: `diff_summary` — 신규/수정/삭제/리네임 파일, merge-base 계산, dirty worktree; `watch.board` tail·limit·손상 행 스킵.
- **socket e2e (`tests_v2/`)**:
  1. `fleet.state` 스키마 — 팀+task+worktree 셋업 후 approvals/watch 필드 검증.
  2. approve 해피패스: delegate `--worktree always` → 파일 수정+커밋 시뮬레이션 → `task review` → `team.task.approve` → parent 브랜치에 머지 확인 + task `completed` + `worktree_removed`.
  3. approve 가드: dirty worktree → 실패 + blocked 아님(에러 반환만); CLI `finish-worktree`와 동시 실행 → lock으로 한쪽 실패.
  4. reject → status 되돌림 + agent 수신 확인(`tm-agent read`).
  5. `agent_state` 매핑: 알림 생성 → `waiting_input`, park → `parked` 등 상태표 전수.
- **대시보드**: 기존 대시보드 검증 방식(XCUITest 최소화, 스냅샷 기반)에 맞춰 `updateFleet` JS를 mock payload로 단위 검증하는 정적 하네스 추가.

## 9. 단계별 출시

| 단계 | 범위 |
|------|------|
| **P1** | `agent_state` 통합 + `fleet.state` + `watch.board` + mission 프리셋(매트릭스·heartbeat·watch 타임라인, 폴링) |
| **P2** | 승인 큐 전체 (`diff_summary`, approve/reject RPC, 카드 UI, 딥링크 알림) |
| **P3** | push 전송(`events.subscribe` 확장 + SSE), finish-worktree CLI의 RPC 위임, teamOps 프리셋 흡수 검토 |

의존성: 승인 큐의 내구성은 Restore Fleet 설계의 board 영속화(Layer 2)에 기대지만, **하드 의존은 아니다** — board가 휘발이어도 큐는 동작하고, 영속화가 들어오면 재시작 생존이 공짜로 따라온다.

## 10. 미해결 질문

1. 매트릭스의 축 — 팀이 여러 개일 때 팀별 섹션 vs 단일 평면 리스트(팀 칩 표시). 초안: 단일 평면 + 팀 필터 (인스턴스당 팀 수가 보통 1~2개).
2. 승인 카드에서 파일별 diff 뷰를 어디까지 인앱으로 끌어올릴 것인가 — v2에서 브라우저 패널에 `git-kit diff` HTML 렌더를 띄우는 방안 검토 (기존 브라우저 스플릿 인프라 재사용).
3. HTTP(원격 브라우저) 경로에서 approve를 허용할 것인가 — 초안: v1은 **로컬 WKWebView 전용**(원격 승인은 로드맵 §D-3 모바일 승인에서 인증 설계와 함께).
