# 제안: Autonomous Watch 실행 모델 — Headless One-shot의 가시성 문제와 Pane Recycle 전환

상태: §2a/§2b/§5.3/§5.4 구현 완료(브랜치 `fix/headless-cli-path-spawn`), §4 pane recycle 전환은 설계 확정(§7) → 구현 대기

해결 진행 (2026-06-02):
- **§2a Spawn PATH** ✅ `compose_agent_path` — daemon bin + 표준 사용자 bin(~/.local/bin 등) prepend (ac226ea5)
- **§2b 에러 가시성** ✅ `last_success_ts`/`consecutive_failures` 분리 + status `health`/`error` 노출 (a3e30bc6)
- **§5.3 read 스코프** ✅ `resolve_team_name` + global `--team` (모든 agent-side 명령 공통) (64354760)
- **§5.4 PATH 범용성** ✅ 표준 bin prepend가 codex/gemini/kiro/claude 전부 커버 (ac226ea5)
- **§4 pane recycle 전환** → §7 ADR로 설계 확정, 구현은 별도 phase
범위: term-meshd (Rust) `watch_controller` + `headless::one_shot` + watch status/config 직렬화. 부수적으로 term-mesh app (Swift) pane recycle 경로.
관련 문서: [watcher-pair-programming.md](./watcher-pair-programming.md), [leader-as-watch-target.md](./leader-as-watch-target.md), [watch-gui-prd.md](./watch-gui-prd.md), [.claude/commands/watch.md](../.claude/commands/watch.md)

## 1. 발단 (실측 incident)

`/watch on`을 leader self-watch(worker 0인 attach 부트스트랩 팀 `ws-576cbd21`, `--cli codex --stance pair --spec preset:general --every 300`)로 켜고 **실제로 동작하는지 검증**하던 중, autonomous tick이 **100% 실패하고 있었음**을 발견했다. 그런데 그 실패가 어디에도 드러나지 않아 두 번 오진했다.

표면 신호는 전부 "정상"으로 보였다:

```
$ tm-agent watch status ws-576cbd21
  enabled:   yes
  last_tick: 1780357818 (3m ago)   # ← 갱신됨 → "도는 것처럼" 보임
  next_tick: 1780358118 (in 1m)    # ← 예약됨
  drifts:    1                      # ← board의 과거 잔재(05-27) 줄 수일 뿐
```

그러나 `.xm/watch/config.json`의 진실은 정반대였다:

```json
"ws-576cbd21": {
  "last_check_ts": 0,        // 실제 체크 = 한 번도 없음
  "check_count": 0,          // 실행 횟수 = 0
  "in_flight": false,
  "last_error": null,        // ← 에러 없음으로 표기
  "app_socket_path": null
}
```

대조군 — 같은 데몬의 `standard` 팀(`--cli claude`): `check_count: 80`, `app_socket_path: "/tmp/term-mesh.sock"`. **claude watcher는 80회 정상, codex watcher는 0회.**

데몬 로그(`/private/tmp/term-meshd.log`)가 진짜 원인을 보여줬다 — tick은 매 300s 발화하지만 매번 spawn 단계에서 죽는다:

```
INFO  term_meshd::headless: spawning headless agent:
      watcher-7988d760-...@ws-576cbd21 (cli=codex, model=sonnet, resume=false)
WARN  term_meshd::watch_controller: watch check error: team=ws-576cbd21
      check=984464a1... target=leader
      error=spawn failed: failed to spawn 'codex': No such file or directory (os error 2)
```

(23:45, 23:50, 23:55 … 300s 간격으로 반복)

## 2. 근본 원인

### 2a. Spawn PATH (1차 원인)

데몬이 watcher CLI를 spawn할 때 **사용자 환경 PATH를 확보하지 못한다.**

- codex 설치 위치: `/Users/jinwoo/.local/bin/codex`
- 데몬 PATH: `/Applications/term-mesh.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin` — **`~/.local/bin` 없음**

GUI 앱(`term-mesh.app/Contents/MacOS/term-mesh`, PID 63485)이 띄운 데몬(PID 63545)이 소켓·tick을 담당하는데, GUI 프로세스는 login shell PATH를 상속받지 않아 `~/.local/bin/codex`가 안 보인다. `claude`는 데몬 PATH에 있어 동작하므로 그동안 문제가 가려져 있었다.

코드 경로:
- `daemon/term-meshd/src/headless/one_shot.rs:290-319` — `RealRunner`가 `HeadlessManager::spawn_agent(SpawnParams{ cli_path, ... })` 호출. 실패 시 `WatchCheckOutcome { spawned: false, error: Some("spawn failed: {e}") }` 생성(one_shot.rs:318-319).
- `SpawnParams.cli_path: Option<String>`는 이미 존재(one_shot.rs:111, 296)하나 **`tm-agent watch on`에 `--cli-path` 플래그가 없어** 외부에서 풀패스를 주입할 길이 없다(현재 config의 `cli_path`는 항상 `null`).
- 실제 `Command` 환경/PATH 설정 지점은 `daemon/term-meshd/src/headless/cli_builder.rs` 추정 — 수정 시 확인 필요.

### 2b. 에러 가시성 (동반 원인, 더 위험)

spawn 실패가 WARN 로그엔 찍히지만 **운영 표면 어디에도 전파되지 않는다.** 이것이 incident를 80+회 은폐한 진짜 문제다.

- `WatchCheckOutcome.error`는 채워지는데(one_shot.rs:319) `config.last_error`는 `null` 유지 → `watch status`에 안 뜸.
- `watch status`의 `last_tick`/`next_tick`은 **성공/실패와 무관하게 진행** → 실패를 정상으로 오인하게 만듦.
- 결과적으로 `check_count`(=0)와 `last_tick`(진행 중)이 모순인데 status는 후자만 보여준다.

→ **수정**: spawn 실패(및 모든 `outcome.error`)를 `config.last_error`에 persist하고 `watch status`에 노출. `last_tick`은 *성공한 체크에만* 갱신해 `check_count`와 일관되게.

## 3. 핵심 통찰

설계 의도상 autonomous tick은 만들어둔 watcher pane을 **쓰지 않고**, 매 tick `resume=false`로 새 headless watcher(`watcher-<uuid>@team`)를 spawn한다(one_shot.rs:3-7: *"Each autonomous watch tick spawns a fresh headless watcher (no GUI pane) … A fresh spawn … is exactly what would make the watcher itself drift"*). stateless 보장을 위한 결정이다([watcher-pair-programming.md](./watcher-pair-programming.md) §2).

그 결과 가장 아이러니한 상황이 벌어졌다:

> **사용자 shell에서 떠서 `~/.local/bin/codex`를 멀쩡히 실행 중인 watcher pane이 옆에 있는데, 데몬은 그걸 안 쓰고 자기 빈약한 PATH로 새 codex를 spawn하려다 매번 죽는다.**

즉 headless one-shot 모델은 (a) PATH를 데몬에 의존하고 (b) 실행 과정이 불투명해 실패를 은폐한다. 두 약점이 이번 incident에서 동시에 터졌다.

## 4. 결정: Pane Recycle 기반 실행 모델로 전환

`pair` stance는 **가시성도 가치의 일부**다 — `[CRITIC]`/`[ADVISOR]` 두 관점의 대조 추론이 보여야 사용자가 신뢰·교정할 수 있다. headless one-shot은 이 가시성을 버린다. 그리고 *"어차피 headless 오류는 여태 못 잡았다"* — 가시성 부재가 실패 은폐의 직접 원인이었다.

### stateless의 재해석

watch의 본질은 **"매 체크가 spec + bounded delta만 입력받는다"**이지, "프로세스가 매번 새것"이 아니다. pane을 `recycle`(누적 컨텍스트 drop)한 뒤 send하면 stateless 정신을 충족하면서 가시성·PATH우회·pair가치를 모두 얻는다. 완전 fresh가 꼭 필요하면 `recycle` 대신 `restart --hard`(새 pane respawn, scrollback 손실) 선택지도 있다.

### Headless one-shot vs Pane recycle

| | headless one-shot (현재) | pane recycle (제안) |
|---|---|---|
| 가시성 | ✗ 로그 파야 함 | ✓ pane에서 verdict 직접 관찰 |
| 오류 인지 | ✗ 조용히 실패 | ✓ spawn/실행 오류가 pane에 노출 |
| PATH 문제 | ✗ 데몬 빈약 PATH 의존 | ✓ pane은 사용자 shell PATH (codex 찾음) |
| pair 추론 | ✗ 안 보임 | ✓ [CRITIC]/[ADVISOR] 대조 가시적 |
| stateless | ✓ 완전 (새 프로세스) | △ recycle = 컨텍스트 drop 수준 |
| 속도/focus | 빠름·백그라운드 | recycle 오버헤드·focus-safe 주의 |

### 하이브리드 실행 모델

autonomous tick 실행을 팀 형태로 분기:

- **GUI pane 보유 팀** (leader self-watch 포함) → 떠 있는 watcher pane을 `recycle` 후 send → pane에서 가시적으로 verdict 산출 → read로 회수 → `WatchController`가 board/leader inbox 기록.
- **순수 headless 팀** (GUI pane 없음) → 기존 `headless::one_shot` spawn fallback 유지.

이러면 §2a(PATH)와 §2b(가시성)의 가시성 측면이 GUI pane 케이스에서 **구조적으로 해소**된다 — pane이 곧 대시보드라 실패가 즉시 보인다. 단 §2b의 `last_error` persist + `last_tick` 정합 수정은 headless fallback을 위해 **여전히 필요**하다.

## 5. 미해결 / 검증 과제

1. **focus-safe**: `recycle` + send가 백그라운드로 inject되고 pane focus를 뺏지 않는지 확인. term-mesh send는 데몬 백그라운드 주입이라 괜찮을 가능성이 높지만, `recycle` 시 pane 활성화가 끼는지 코드 확인 필요(recycle 구현: `daemon/term-meshd/src/socket.rs`, `agent.rs`, `Sources/TeamOrchestrator.swift`).
2. **recycle의 stateless 강도**: `recycle`이 CLI 세션 컨텍스트를 어디까지 비우는지 — 불충분하면 `restart --hard`로 격상.
3. **read 스코프 버그(별건)**: 워크스페이스-로컬 팀(`ws-…`)에서 `tm-agent read`/`collect`/`inbox`가 기본 팀 `live-team`으로 해석돼 대상 팀을 못 가리킴. manual `/watch review`가 이 팀에서 동작 불가한 원인이며, pane recycle 회수 경로 설계 시 같이 고려.
4. **PATH 수정의 범용성**: §2a는 codex뿐 아니라 gemini/kiro 등 사용자별 설치 CLI 전반의 문제. headless fallback을 살린다면 login-shell PATH 로드(`zsh -lc` 등) 또는 표준 사용자 bin 경로 prepend로 근본 해결.

## 6. 실측 부록

- 데몬: GUI 앱(PID 63485)이 띄운 PID 63545가 소켓(`/tmp/term-mesh.sock`, 08:37 생성)·tick 담당. PID 2148은 launchd 직속 orphan(소켓 없음).
- 로그: `/private/tmp/term-meshd.log` (데몬 stdout/stderr).
- codex: `/Users/jinwoo/.local/bin/codex` (데몬 PATH 밖).

## 7. 설계 결정 (ADR) — §4 Pane Recycle 실행 모델

상태: 결정 (코드 조사 기반, 2026-06-02). 구현 전. 라이브 검증 필수.

### 7.1 결정

autonomous watch tick의 watcher 실행을 **팀 형태로 분기**한다.

- **GUI watcher pane 보유 팀** → 떠 있는 watcher pane을 `recycle`(hard restart로 컨텍스트 drop) → spec을 `send` → verdict를 `read`로 회수. pane이 곧 대시보드라 실패가 즉시 보인다.
- **순수 headless 팀** → 기존 `headless::one_shot` fresh-spawn fallback 유지.

### 7.2 검증된 전제 (코드 조사)

| 과제 | 결론 | 근거 |
|---|---|---|
| §5.1 focus-safe | ✅ 안전 | `team.restart`/`team.send`/`team.read` 모두 focus-intent allowlist 밖 → `withSocketCommandPolicy`가 focus mutation 차단(`TerminalController.swift:52-78,179-194`). recycle은 `addAgentPaneToWorkspace(focus:false)` + `preserveFocusAfterNonFocusSplit`(`Workspace.swift:1101-1113`). send는 `sendIMEText`→`enqueuePaste` 백그라운드 주입. read/collect는 read-only. |
| §5.2 recycle stateless 강도 | ✅ 충분 (격상 불요) | `recycle` = `team.restart mode=hard`(`tm_agent.rs:5494-5502`) → pane close+respawn, `--resume` 없이 새 CLI 세션(`claudeSessionId:nil`, `TeamOrchestrator.swift:735`), scrollback 손실. watch stateless 계약("spec + bounded delta만")을 충족·초과. |
| recycle 비용 | ✅ 적합 | ~300–700ms ≪ 300s interval. `in_flight` 가드로 overrun skip. recycle은 active-task 가드 있는 safe variant. |
| 분기 판정 | ✅ 가능 | 데몬 `HeadlessManager.teams.contains_key(team)` == false → Swift GUI 팀. one_shot.rs:249 `run_check_impl` 진입부가 분기점. |

### 7.3 리스크 / 미해결

1. **verdict 회수 파싱 (최대 난점).** headless는 structured stdout(`result` 이벤트)을 파싱하지만, pane recycle 경로는 `team.read`로 **터미널 스크롤백 텍스트**를 읽는다 — ANSI/프롬프트/CLI 장식이 섞여 verdict 블록 추출이 취약하다.
   - 완화책: watcher prompt가 verdict를 sentinel 마커(예 `<<<WATCH-VERDICT>>> … <<<END>>>`)로 감싸 출력하게 하고, WatchController가 마커 사이만 추출. 마커 부재/타임아웃은 실패로 기록(§2b health 경로).
2. **app_socket_path null.** GUI 경로는 데몬이 app socket으로 `team.*` RPC를 보내야 하는데, `watch.on`은 `TERMMESH_SOCKET`이 app socket일 때만 주입한다(`tm_agent.rs:6329`). §1의 ws-576cbd21은 null이었다(adopt leader pane env 결핍 — §5.3과 동일 뿌리). → GUI 경로의 **선결 조건**: adopt 시 app socket 확보(P2).
3. **read 대상 정합.** recycle/send/read가 올바른 팀(`ws-…`)을 가리켜야 한다 → §5.3 fix(완료)에 의존.
4. **headless fallback 유지.** §2b(last_error/last_success 분리)는 fallback 경로를 위해 **여전히 필요**(이미 구현).

### 7.4 대안 (기각)

- **headless one_shot에 PATH만 보강하고 실행 모델은 유지** — §2a로 이미 적용(codex 뜸). 단 가시성(§2b 표면 노출은 했으나 *추론 과정*은 여전히 안 보임)과 pair 가치는 회복 못 함. "더 나은 모델"로서 §4는 유효하나 긴급성은 낮아짐.
- **항상 pane recycle (headless 폐기)** — 순수 headless 팀(GUI pane 없음)에서 불가. fallback 필수라 기각.

## 8. 구현 분해 (phase)

| Phase | 내용 | 상태 |
|---|---|---|
| P0 | §2a PATH / §2b 가시성 / §5.3 team resolution | ✅ 완료 |
| P1 | **app_socket_path 확보** — adopt leader pane이 `watch.on`에 app socket 전달(또는 watch.on이 데몬에서 app socket 해석). GUI 경로 선결. | ⬜ |
| P2 | **분기 + GUI 경로** — one_shot.rs:249에 `manager.teams.contains_key` 분기. GUI 팀 → app socket으로 `team.restart(hard)` → `team.send(spec)` → `team.read(verdict)`. | ⬜ |
| P3 | **verdict 파싱** — sentinel 마커 기반 추출. 마커 부재/타임아웃 → 실패 기록(§2b). | ⬜ |
| P4 | **headless fallback 유지 + 단위 테스트** — 분기 판정, 마커 파싱, 타임아웃. | ⬜ |
| P5 | **라이브 검증** — ws-팀 leader self-watch + codex로 recycle tick 실제 동작/focus-safe/verdict 회수 확인. | ⬜ |

각 phase는 ship + commit + pause. P1(app_socket)이 GUI 경로의 선결이라 먼저다.
