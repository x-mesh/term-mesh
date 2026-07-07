# 상세설계 — 세션·팀 영속화와 Restore Fleet

작성일: 2026-07-07
상태: P1+P2 구현됨 (Layer 1 + 2 + 3)

구현 상태 (2026-07-07):
- 데몬: schema v2(`live`/`last_snapshot_at`/`layout_workspace_title`/`session_id_captured_at`), `team.snapshot_pane`, `headless.list_live_pane`, `resume_pane`의 live 디렉토리 지원, stale live 스냅샷 GC 강등 — **구현 + 단위테스트 통과** (`cargo test -p term-meshd headless`).
- Swift: `syncTeamStateToDaemon` 훅 기반 디바운스 live 스냅샷(직렬 persist 큐 + retire/revive 게이트), `TeamTask: Codable`, `TeamDataStore` board.json 영속화(`~/.term-mesh/teams/<uuid>/board.json`) + pane-resume 시 `loadBoard`(in_progress→assigned 정규화) — **구현됨, macOS 빌드 검증 필요** (이 작업은 Linux 환경에서 수행되어 xcodebuild 미실행).
- Layer 3: `detectRestorableFleets`(launch +1.5s, `headless.list_live_pane` + 인스턴스 소켓 필터 + 라이브 팀 uuid 제외), 사이드바 `SidebarFleetRestoreBanner`(ask 모드), `fleetRestoreMode` UserDefaults 키(ask/always/never — Settings UI는 후속), `restoreFleet` → `team.resume_pane` → `adoptResumedPaneTeam`(worker `--resume` 포함 — 기존 배선 사용) + sid transcript 존재 가드(worktree off 팀·leader) — **구현됨, macOS 빌드 검증 필요**.
- 미구현 (후속): 복원 직후 assigned task 자동 재디스패치 킥(§3.3 시퀀스 5단계) — CLI 기동 타이밍 race를 피하기 위해 보류. 복원된 task는 `assigned`로 보드에 노출되며 리더가 `tm-agent broadcast 'tm-agent claim'` 한 번으로 재개.
- Layer 3 주의(구현 반영됨): resume 직후 앱이 스냅샷을 다시 쓰기 전에 데몬이 재시작하면 같은 uuid가 archived와 live 양쪽에 존재할 수 있다. 현재 배너는 live만 열거하고 기존 피커는 archived만 열거하므로 충돌하지 않지만, 두 목록을 합치는 UI를 만들 때는 uuid dedupe(live 우선)가 필요하다.
상위 문서: `docs/strategy-differentiation-roadmap.md` §B-1
관련 코드: `Sources/TabManager.swift`, `Sources/TeamOrchestrator.swift`, `Sources/TeamDataStore.swift`, `daemon/term-meshd/src/headless/meta.rs`, `daemon/term-mesh-cli/src/tm_agent.rs`

---

## 1. 목표

앱 재시작(정상 종료·크래시·머신 재부팅) 후 **한 번의 액션으로 함대 전체를 복원**한다:

- 워크스페이스 레이아웃 (현재도 복원됨)
- **팀 구성 + 각 에이전트 pane** (현재: 수동 resume 피커, leader만 `--resume`)
- **각 에이전트의 CLI 대화 컨텍스트** (`claude --resume <sid>`)
- **task board / 메시지 / context store** (현재: 전부 인메모리, 유실)
- 진행 중이던 worktree task의 재개 가능 상태

비목표(Non-goals):
- pane 터미널 스크롤백/출력 자체의 복원 (CLI `--resume`이 대화 컨텍스트를 복원하므로 불필요)
- 비 Claude CLI(codex/kiro/gemini)의 대화 복원 — 어댑터가 생기기 전까지는 "역할 재구성"(runbook digest + task capsule)으로 대체
- 원격(peer) 팀 복원 — peer × team 설계(별도)로 이관

## 2. 현재 상태 (As-Is) 요약

| 상태 | 저장 위치 | 저장 시점 | 복원 |
|------|----------|----------|------|
| 워크스페이스 레이아웃 | `~/Library/Application Support/com.termmesh.app/session.json` (`SavedSessionState` v2, `Sources/TabManagerSettings.swift:62`) | 변경 시 0.5s 디바운스 + 30s 주기 타이머 + 종료 시 (`TabManager.swift:452,181,AppDelegate.swift:670`) | 앱 시작 시 자동 (`TabManager.swift:474-546`) |
| 팀/에이전트 메타 | `~/.term-mesh/headless/<team_uuid>/{team.json, agents/*.json, instructions/*.txt}` (`meta.rs:31-100`, schema v1) | **destroy 또는 정상 종료 시에만** (`archive_pane_team`, `TeamOrchestrator.swift:4240`, `AppDelegate.swift:675`) | 수동 resume 피커 (`headless.list_resumable` → `team.resume_pane`) |
| Claude session id | pane 모드: FSEvents로 `~/.claude/projects/…/<sid>.jsonl` 파일명 캡처 → `AgentMember.claudeSessionId` (인메모리, `TeamOrchestrator.swift:724,4213`) | 캡처 시점 (디스크 기록은 archive 시) | leader만 `--resume` (`:1044`); worker는 fresh 재기동 (`:4079`) |
| task board | `TeamDataStore.taskBoards` (인메모리, `TeamDataStore.swift:57`) | 없음 | **불가 — 유실** |
| 메시지/heartbeat/context | `TeamDataStore` 인메모리 (`:56-59`) | 없음 | **불가 — 유실** |
| 에이전트 결과 파일 | `~/.term-mesh/results/<team>/` (Rust, 영속) + `/tmp/term-mesh-team-<team>/` (Swift, 휘발) | 즉시 | 파일은 남으나 board가 없으면 참조 유실 |

핵심 문제 3개:
1. **크래시 = 팀 전소.** 아카이브가 destroy/quit 시점에만 쓰이므로 비정상 종료 시 팀 메타조차 없다.
2. **task board 비영속.** `tm-agent recycle`의 전제("durable state remains in the task board")가 재시작 경계에서 깨진다.
3. **worker resume 미구현.** sid는 캡처되지만 재기동 시 사용되지 않는다 (배선은 존재: `addAgentPaneToWorkspace(resumeSessionId:)` `TeamOrchestrator.swift:661-665`).

## 3. 설계 개요

세 개의 독립적 계층으로 나눈다. 각각 단독 배포 가능하다.

```
Layer 1  Live Team Snapshot   팀 상태를 "종료 시 아카이브"에서 "변경 시 스냅샷"으로 전환
Layer 2  Board Journal        task board/메시지/context의 앱-측 영속화
Layer 3  Restore Fleet UX     launch 시 감지 → 원클릭 복원 (레이아웃+팀+resume+board)
```

### 3.1 Layer 1 — Live Team Snapshot

기존 아카이브 포맷(`~/.term-mesh/headless/<team_uuid>/`)을 재사용하되, 쓰기 시점을 바꾼다.

- **쓰기 트리거**: `TeamOrchestrator`의 팀 변형 지점(create/attach/detach/swap/restart/park, `claudeSessionId` 캡처, `completedTaskCount` 증가)에서 `scheduleTeamSnapshot(teamName:)` 호출. `TabManager.scheduleSessionSave`와 동일한 0.5s 디바운스 + 직렬 큐 패턴.
- **RPC**: 기존 `team.archive_pane`를 일반화한 `team.snapshot_pane` 데몬 RPC 추가. `archive_pane_team`(`daemon/term-meshd/src/headless/mod.rs:1312`)과 동일 페이로드에 `live: true` 플래그. live 스냅샷은 디렉토리를 `.archived.<ts>`로 rename하지 않고 `<team_uuid>/` 그대로 유지·덮어쓴다(기존 atomic tmp+fsync+rename 재사용, `meta.rs:135-172`).
- **스키마 v2** (`TeamMeta.schema = 2`, 하위호환 읽기 유지):
  - `live: bool` — true면 "실행 중이던 팀"(복원 후보), false면 기존 의미의 아카이브.
  - `last_snapshot_at: u64`
  - `layout_workspace_title: String?` — 팀 워크스페이스 제목(복원 시 재사용)
  - `AgentMeta`에 `claude_session_id_captured_at: u64?` 추가 (stale 판단용)
- **생명주기 정합성**:
  - `team destroy` → 스냅샷 디렉토리를 기존처럼 `.archived.<ts>`로 rename (`live=false`).
  - 정상 종료(`archiveAllLivePaneTeamsForQuit`, `AppDelegate.swift:675`) → **rename하지 않고 `live=true` 유지**. "정상 종료된 live 팀"이 다음 실행의 복원 후보다.
  - 크래시 → 마지막 디바운스 스냅샷이 그대로 남는다. 최대 유실 폭 = 디바운스 창 + 진행 중이던 변형 1건.
- **sid 캡처 즉시 영속화**: `recordClaudeSessionId`(`TeamOrchestrator.swift:4213`)가 스냅샷을 트리거하도록 한다. sid는 팀 복원의 핵심 데이터이므로 캡처 즉시 디스크에 있어야 한다.

### 3.2 Layer 2 — Board Journal (task board / 메시지 / context 영속화)

**저장 주체 결정: Swift 앱(TeamDataStore)이 직접 파일을 쓴다.** 근거: board의 단일 진실은 `TeamDataStore`(lock-guarded, `TeamDataStore.swift:46-63`)이고, 데몬 경유는 홉만 늘린다. 데몬은 headless 팀에서 이미 자체 메타를 쓰므로 역할 충돌도 없다.

- **경로**: `~/.term-mesh/teams/<team_uuid>/board.json` (스냅샷 방식). team_uuid는 `Team.teamUuid`(`TeamOrchestrator.swift:55-93`)를 사용해 아카이브 디렉토리와 join 가능하게 한다.
- **포맷**: 단일 JSON 스냅샷 (append-only journal 대비 결정 근거: board 크기가 작고 — 수십 task × ~1KB — 컴팩션 로직이 불필요. 이벤트 이력이 필요해지면 감사 로그(§C-2 로드맵)에서 다룬다).

```json
{
  "schema": 1,
  "team_uuid": "…",
  "team_name": "my-team",
  "saved_at_ms": 1780000000000,
  "tasks": [ { …TeamTask 전체 필드, taskDictionary와 동일 직렬화… } ],
  "messages": [ { "from": "…", "to": "…", "text": "…", "ts": … } ],
  "context": { "<key>": "<value>" }
}
```

- **쓰기 트리거**: `TeamDataStore.onDataChanged`(`TeamDataStore.swift:86`)에 이미 존재하는 디바운스 훅을 재사용 — 현재 `team.sync` 데몬 푸시가 걸려 있는 지점에 파일 쓰기를 병렬 추가. 직렬 IO 큐 + atomic write(tmp→rename).
- **제외 항목**: heartbeat(초 단위 갱신·재시작 후 무의미), agentUsage(데몬이 원천), watchDrifts(원천이 `.xm/watch/board.jsonl`로 이미 영속).
- **로드**: 팀 복원 시(§3.3) 또는 동일 세션 내 재-adopt 시 `TeamDataStore.loadBoard(teamUuid:)` → 기존 CRUD 검증 경로(`createTask`의 dedup/의존성 검증 `TeamDataStore.swift:257`)를 우회하고 통째로 주입하되, 로드 직후 **상태 정규화**를 1회 수행한다:
  - `in_progress` → `assigned` + `lastProgressAt` 유지 (작업 프로세스가 죽었으므로 "진행 중"일 수 없다; auto-claim이 재개를 담당)
  - `review_ready`/`blocked`/`completed`/`failed` → 그대로
  - worktree 필드는 그대로 (worktree는 디스크에 실재하므로 `finish-worktree` 재개 가능)
- **정리**: `team destroy` 시 board 파일을 아카이브 디렉토리로 이동(`.archived` 팀과 동일 GC — 7일, `meta.rs:27`).

### 3.3 Layer 3 — Restore Fleet UX

**감지 (launch 시)**
1. `TabManager.loadSavedSession()` 완료 후 `TeamOrchestrator.detectRestorableFleet()` 실행.
2. 데몬 RPC `headless.list_resumable`을 확장한 `headless.list_live`로 `live=true`인 스냅샷 목록 조회 (앱 인스턴스 격리: 스냅샷에 socket path suffix/bundle id를 기록해 prod/STAGING/tag 인스턴스 간 오염 방지 — 0.142.0에서 고친 라우팅 문제와 동일 원칙).
3. 후보가 있으면 설정 `fleetRestoreMode`에 따라 분기:
   - `ask`(기본): 사이드바 상단 배너 "이전 함대 발견: my-team (agents 4 · tasks 7) — [Restore] [Dismiss]". 기존 resume 피커(`SidebarViews.swift:178-244`)를 배너형으로 승격.
   - `always`: 자동 복원.
   - `never`: 무시(수동 피커는 유지).

**복원 시퀀스 (팀당)**

```
1. 워크스페이스 생성        기존 resumePaneTeam/adoptResumedTeam 경로 재사용 (TeamOrchestrator.swift:3951-4079)
2. leader pane 기동         claude --resume <leader sid>            (기존 동작)
3. worker pane 기동          agent별:
                             - cli == claude && claudeSessionId 존재 && jsonl 파일 실재
                               → addAgentPaneToWorkspace(resumeSessionId: sid)   (기존 배선 :661)
                             - 그 외 → fresh 기동 + runbook digest (기존 동작)
                               fresh 기동 직후 리더가 아니라 시스템이 task capsule 재주입(5단계)
4. board 로드 + 정규화       TeamDataStore.loadBoard (§3.2)
5. 재개 킥                   기존 auto-claim 경로 재사용: 정규화로 assigned가 된 task를
                             assignee에게 재푸시 (dispatchTaskToAssignee 경로),
                             unassigned pool은 broadcast 'tm-agent claim' 1회
6. 검증                      각 pane의 CLI 프로세스 기동 확인 (AutoReplyPoller가 살아있는지),
                             실패 pane은 사이드바에 "복구 실패 — 수동 재시작" 배지
```

**resume 유효성 가드**
- `--resume <sid>` 전 `~/.claude/projects/<encoded-workdir>/<sid>.jsonl` 존재 확인 (`discoverClaudeSessionId` 로직 재사용, `TeamOrchestrator.swift:4271`). 없으면 fresh로 강등하고 사유를 dlog + 배너에 표기.
- workdir가 사라진 경우(worktree 삭제 등): `originalAgentWorkDir` → 존재하지 않으면 git repo root로 강등.
- resume은 **Claude CLI 한정**으로 시작. codex/kiro/gemini는 어댑터 프로토콜(각 CLI의 세션 재개 커맨드 유무 조사)을 후속 스파이크로 분리.

## 4. 변경 지점 목록

| 컴포넌트 | 변경 | 크기 추정 |
|----------|------|----------|
| `daemon/term-meshd/src/headless/meta.rs` | schema v2 필드 (`live`, `last_snapshot_at`, …), 하위호환 읽기 | S |
| `daemon/term-meshd/src/headless/mod.rs` | `team.snapshot_pane`(live 덮어쓰기), `headless.list_live`, destroy 시 rename 정책 | M |
| `Sources/TeamOrchestrator.swift` | `scheduleTeamSnapshot` 디바운스, 변형 지점 훅, `detectRestorableFleet`, 복원 시퀀스(worker resume 포함), quit 시 rename 안 함 | L |
| `Sources/TeamDataStore.swift` | `saveBoard`/`loadBoard` + onDataChanged 훅 + 상태 정규화 | M |
| `Sources/SidebarViews.swift` | Restore 배너 UI | S |
| `Sources/TerminalController.swift` | (선택) `team.board.export/import` v2 RPC — 테스트·디버그용 | S |
| 설정 | `fleetRestoreMode` (ask/always/never) Settings 항목 | S |
| `tm-agent` | 변경 없음 (복원 후 기존 claim/dispatch 경로가 그대로 동작해야 함 — 호환성 테스트만) | — |

## 5. 엣지 케이스

- **이중 실행**: 같은 스냅샷을 두 앱 인스턴스가 복원 시도 → 스냅샷에 `restored_by_pid`/lock 파일 (`/tmp/term-mesh-restore-<uuid>.lock`, worktree lock 패턴 `tm_agent.rs:8578` 재사용).
- **부분 실패**: worker 3/4만 복원 성공 → 팀은 살리고 실패 agent만 배지. 복원을 all-or-nothing으로 만들지 않는다.
- **스냅샷과 board의 불일치** (스냅샷엔 agent가 있는데 board의 assignee가 없는 경우 등): board 로드 후 `reassignTask`가 아니라 unassigned로 되돌려 pool에 넣는다.
- **오래된 스냅샷**: `last_snapshot_at`이 7일 초과면 복원 후보에서 제외하고 아카이브 GC 경로로.
- **`--resume` 실패 (CLI가 세션을 못 찾음)**: pane에 에러가 표시된 채 idle → AutoReplyPoller가 감지 못함. 복원 시퀀스 6단계에서 기동 후 N초 내 CLI 프롬프트 미감지 시 fresh 재시도 1회.
- **디바운스 창 내 크래시**: 마지막 스냅샷 기준 복원 — task 1~2건의 상태가 과거일 수 있음. 정규화 규칙(in_progress→assigned)이 이중 실행을 방지하는 방향으로 보수적이므로 안전(중복 작업보다 재작업이 낫다).

## 6. 테스트 전략

- **daemon 단위 (Rust)**: meta v1→v2 하위호환 읽기, live 덮어쓰기 원자성, destroy rename, list_live 필터.
- **socket e2e (`tests_v2/`, VM)**:
  1. 팀 생성 → task 3개(1 in_progress, 1 review_ready, 1 unassigned) → 앱 kill -9 → 재기동 → `fleetRestoreMode=always` → `team.status`로 팀·agent 수 검증, `team.task.list`로 상태 정규화(in_progress→assigned) 검증.
  2. worker resume: claude pane에 marker 텍스트 입력 → 재기동 복원 → `surface.read_text`로 `--resume` 인자 포함 기동 확인.
  3. 이중 인스턴스 lock: 태그 빌드 2개 동시 기동 시 한쪽만 복원.
- **회귀 가드**: 기존 `scripts/test-parallel.sh --skip-team-create`가 복원된 팀에서도 통과해야 함 (auto-claim/round-robin 경로 불변 확인).

## 7. 단계별 출시

| 단계 | 범위 | 사용자 가치 |
|------|------|------------|
| **P1** | Layer 1 + 2 (스냅샷·board 영속화만; 복원은 기존 수동 피커) | 크래시에도 팀 메타·board 생존; 수동 resume의 데이터 품질 향상 |
| **P2** | Layer 3 (배너 + 복원 시퀀스 + worker `--resume`) | "Restore Fleet" 원클릭 |
| **P3** | 결과 디렉토리 통합(`/tmp/term-mesh-team-*` → `~/.term-mesh/results/` 일원화), 비 Claude CLI resume 어댑터 스파이크 | 정합성·멀티 CLI |

## 8. 미해결 질문 (구현 전 결정 필요)

1. pane 모드도 headless처럼 spawn 시 `--session-id <uuid>`를 선주입할 것인가? (FSEvents 캡처 제거 가능, 단 CLI 버전별 `--session-id` 동작 차이 검증 필요 — 스파이크 항목)
2. 메시지 큐(`messages`)를 board.json에 포함할지, 유실 허용(inbox는 task 상태에서 재합성 가능 — `inboxItems`가 이미 그렇게 동작, `TeamOrchestrator.swift:5140`)할지. 초안: task-파생 inbox면 충분하므로 **메시지는 제외**하고 스키마에 자리만 예약.
3. `fleetRestoreMode=always`를 기본값으로 승격할 시점 (P2 안정화 후 텔레메트리로 판단).
