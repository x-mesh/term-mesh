# 제안: Leader-as-Watch-Target (빈 팀에서 leader 자체를 감시)

상태: Implemented (feat/leader-as-watch-target)
범위: term-meshd (Rust) + term-mesh app (Swift) + `/watch` 커맨드 문서
관련 문서: [watcher-pair-programming.md](./watcher-pair-programming.md), [watch-gui-prd.md](./watch-gui-prd.md), [.claude/commands/watch.md](../.claude/commands/watch.md)

## 1. 문제

`/watch on`을 worker가 없는 팀(예: `attach`로 leader+watcher만 부트스트랩한 1인 팀)에서 켜면 감시 대상이 0개라 실효 tick이 돌지 않는다.

```
$ tm-agent watch status ws-34e81234
  enabled:   yes
  running:   no
  target:    all
  last_tick: never        # ← worker가 없어 영원히 never
```

그러나 그런 팀에서도 **실무(코드 수정·분석)는 leader pane에서 일어난다**. drift가 발생하는 바로 그곳을 감시하지 못하는 것이다. 직관적으로는 "감시할 worker가 없으면 leader를 보거나, leader와 짝(pair)을 이뤄야" 한다.

## 2. 현재 동작과 근본 원인 (코드 근거)

leader가 watch 대상에서 빠지는 것은 **이름 필터가 아니라 자료구조 분리** 때문이다.

**(a) leader는 `agents[]` 밖, 별도 필드에 저장된다.**
`Sources/TeamOrchestrator.swift:55-93` — `Team`은 `leaderPanelId: UUID`, `leaderSessionId: String`를 별도 필드로 두고, worker/watcher만 `agents: [AgentMember]` 배열에 담는다. daemon 측도 동일(`daemon/term-meshd/src/headless/meta.rs:32-56`의 `TeamMeta.leader: LeaderMeta` vs `agents: Vec<String>`).

**(b) read/collect는 `agents[]`만 조회한다.**
`Sources/TeamOrchestrator.swift:4720-4726`:
```swift
func agentPanel(teamName: String, agentName: String, tabManager: TabManager) -> TerminalPanel? {
    guard let team = teams[teamName] else { return nil }
    guard let agent = team.agents.first(where: { $0.name == agentName }) else { return nil }
    // ↑ agents 배열에서만 검색 — leader는 여기 없음 → nil
    ...
}
```
그래서 `tm-agent read leader`는 `Agent not found`로 죽는다(`Sources/TerminalController.swift:4310-4346`의 `v2TeamRead`가 위 함수에 의존).

**(c) watch.on의 "all" 해석에도 leader가 없다.**
`daemon/term-meshd/src/socket.rs:2059-2085`는 `--target all`일 때 agent 목록에서 `watcher`만 명시적으로 거르고 나머지를 workers로 삼는다. leader는 애초에 목록(`headless.list` / `team.status`의 `agents`)에 없으므로 자동 제외된다.

**(d) leader는 보고처다.**
watcher 디렉티브(`daemon/term-meshd/src/headless/one_shot.rs:25-31`): *"Report to the leader only; never edit files or message other agents."* 보고는 항상 leader inbox로 간다(`daemon/term-meshd/src/watch_controller.rs:251-278`, `team.message.post`에 `to` 없음).

**핵심 발견:** leader도 `leaderPanelId`를 가지므로, GUI pane을 읽는 `readTerminalTextBase64(terminalPanel:)` 메커니즘으로 **leader pane을 캡처하는 것 자체는 기술적으로 가능**하다. 막는 것은 `agentPanel()`의 lookup 범위뿐이다.

## 3. 제안

worker가 0인 팀에서 `/watch`가 **leader pane을 감시 대상으로 삼을 수 있게** 한다. 두 진입 방식:

1. **명시적**: `tm-agent watch on --target leader <team>` (또는 `/watch on leader`).
2. **fallback (사용자 직관)**: `--target all`인데 resolve된 worker가 0개면 자동으로 `leader`를 단일 대상으로 채택한다. worker가 추가되면 다음 tick부터 worker로 전환(leader는 빠짐).

> "leader와 pair"는 `--stance pair`(한 watcher가 critic+advisor 두 블록 생성)와 결합해 달성한다. `/watch`의 pair는 *두 번째 pane*이 아니라 *두 관점*임을 유지한다(ADR: watcher-pair-programming).

## 4. 설계 결정

**D1. opt-in / 보수적 fallback.** leader 감시를 다인 팀의 기본값으로 만들지 않는다. worker가 한 명이라도 있으면 종전대로 worker만 본다. leader는 "달리 볼 대상이 없을 때"의 fallback이거나 명시 지정일 때만.

**D2. 자기 보고(self-watch) 허용 + 표기.** leader를 감시하면 보고가 leader inbox로 가 "자기 점검" 루프가 된다. 이는 순환이지만 무의미하지 않다(사용자가 자기 작업의 drift를 본다). 단 혼동을 막기 위해 보고 메시지에 `self-watch` 표식을 단다(`watch_controller`의 메시지 prefix).

**D3. in-progress 관용.** leader pane은 사용자가 활발히 타이핑·스트리밍하는 중일 수 있다. 미완료 출력을 drift로 오판하지 않도록, target이 leader일 때 review 프롬프트에 "이것은 leader의 진행 중 작업이다; 미완 상태는 drift가 아니다" 관용 문구를 추가한다.

**D4. focus-safe 유지.** read는 터미널 버퍼 캡처(read-only)라 pane 포커스를 빼앗지 않는다. 기존 제약(background tick, `--every` 하한, `in_flight` 중첩 금지)을 그대로 적용한다.

**D5. stateless 유지.** one-shot watcher 모델은 그대로. 바뀌는 것은 `target`이 가리키는 pane뿐이다.

## 5. 구현 변경 지점

### Swift (app) — leader pane을 읽기 가능하게
1. `Sources/TeamOrchestrator.swift:4720` `agentPanel(teamName:agentName:)` — `agentName == "leader"`(또는 `== teamName`)이면 `team.leaderPanelId`로 pane을 반환하는 특수 케이스 추가:
   ```swift
   if agentName == "leader" {
       guard let ws = tabManager.tabs.first(where: { $0.id == team.leaderWorkspaceId }) else { return nil }
       return ws.terminalPanel(for: team.leaderPanelId)
   }
   ```
2. collect 경로(`allAgentPanels` 계열) — leader pane을 `(name: "leader", panel:)`로 포함하는 옵션. `query_gui_team_workers`가 fallback 시 leader를 받을 수 있도록 `team.status` 응답 또는 별도 RPC에 leader를 노출.

### Rust (daemon) — target 해석 + fallback + 보고 표기
3. `daemon/term-meshd/src/socket.rs:2059-2085` watch.on worker resolve — `is_all_target`이고 resolved `names`가 비면 `vec!["leader".to_string()]` fallback. (D1: worker가 있으면 종전대로.)
4. `daemon/term-meshd/src/socket.rs:2904-2942` `query_gui_team_workers` — worker 0건일 때 leader를 fallback으로 반환할지 결정(또는 3에서 처리).
5. `daemon/term-meshd/src/headless/one_shot.rs:181-220` `build_review_message` — `input.target == "leader"`면 D3 관용 문구 추가. delta 미제공 시 안내 명령을 `tm-agent read leader --lines 200`으로 생성(이미 target 문자열을 그대로 쓰므로 1·2가 되면 자동 동작).
6. `daemon/term-meshd/src/watch_controller.rs:251-278` `post_team_message` — target이 leader면 content에 `[self-watch]` prefix(D2).

### 문서
7. `.claude/commands/watch.md` — "leader 제외"를 "worker가 있으면 leader 제외; worker가 0이면 leader fallback(또는 `--target leader` 명시)"로 갱신. Codex IME도 이 공통 command source를 읽는다. `--target`의 `leader` 값과 fallback 동작을 옵션 표·예시에 추가.

## 6. 엣지 케이스 / 리스크

- **adopted leader만 해당.** `attach`로 채택된 leader는 GUI pane(읽기 가능). 그러나 headless 전용 모드의 leader는 `LeaderMeta.session_id`가 Optional이고 daemon이 stdout 버퍼를 갖지 않아 캡처 대상이 아니다 — 이 경우 fallback을 적용하지 않고 "감시 대상 없음"을 그대로 보고한다.
- **노이즈.** leader pane은 사용자 대화·셸 출력이 섞여 worker pane보다 delta가 시끄럽다. D3 + bounded delta(200줄/16KB, `one_shot.rs:35,39`)로 완화하되, false drift가 잦으면 leader 대상 stance를 advisor로 낮추는 것을 권장.
- **보고 루프 피로.** self-watch 보고가 사용자 작업 중 inbox에 끼어든다. `--every` 하한을 leader 대상일 때 더 크게(예: 기본 300 → 600) 둘 수 있다.

## 7. 대안 비교

| 대안 | 내용 | 평가 |
|------|------|------|
| A. worker를 띄워라 | `/tm`으로 executor를 만들고 실무를 내림 | 다인 팀 정석. 그러나 1인 작업 흐름을 강제 변경 — 사용자 의도와 불일치 |
| B. one-shot 검수 | leader 결과물을 `/tm-op pair`로 1회 검수 | 상시 감시 아님. drift를 사후에만 잡음 |
| C. 본 제안 (leader fallback) | 빈 팀이면 leader를 감시 | 사용자 직관에 부합, 변경 최소(주로 lookup 확장), 기존 stateless 모델 보존 |

C가 "실무가 일어나는 곳을 본다"는 watch 본래 목적에 가장 부합하며 변경 표면이 작다.

## 8. 단계적 롤아웃

1. Swift `agentPanel` leader 케이스 + `tm-agent read leader` 동작 확인(읽기만; watch 무관).
2. daemon watch.on fallback(3) + 명시 `--target leader` 경로.
3. `build_review_message` D3 관용 + `post_team_message` D2 표기.
4. `/watch` 커맨드 문서 갱신 + 예시.
5. 회귀: worker가 있는 팀은 leader를 절대 보지 않음(D1)을 테스트로 고정.
