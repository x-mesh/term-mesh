# Watcher — Pair-Programming / Drift Oversight 설계

> 상태: **설계 합의 완료, 구현 전.** 구현은 추후 진행.
> 원안 플랜 파일: `~/.claude/plans/create-new-team-federated-reef.md` (Phase 0 토대만 다룸 — 본 문서가 상위 설계).

## 1. 배경 / 동기

장시간 에이전트 세션은 오류가 누적되며 **drift(이탈)**한다. 출처 컨셉(model-watches-model):
fresh context를 가진 보조 세션이 주기적으로 **spec과 primary의 최근 transcript를 대조**해
이탈을 잡아내고, 어긋났으면 피드백으로 코스를 교정한다.

두 종류의 drift:
- **execution drift** (전술적): 태스크를 *잘못* 수행 — 오류 무시, 잘못된 metric 보고, 스코프 이탈,
  잘못된 파일 수정. → **자주** 점검.
- **direction drift** (전략적): *애초에 잘못된* 태스크 수행 — 의도 오해로 몇 시간째 엉뚱한 것 구축.
  → **가끔** 점검.

term-mesh는 이미 multi-agent 인프라(`tm-agent` collect/read/msg, role/runbook)를 갖췄으므로,
이 위에 watcher를 얹는다.

## 2. 핵심 설계 결정 (합의)

| 항목 | 결정 | 근거 |
|------|------|------|
| **체크 본질** | **stateless** — 매 체크마다 fresh context로 `spec + 최근 delta`만 입력 | watcher 컨텍스트 무한 증가(폭발) 방지 + watcher 자신의 drift 방지. 원안의 "persistent passive pane을 리더가 ping" 방식 폐기 |
| **stance(성격)** | `critic`(기본) / `advisor` / `pair` | "긍정+부정 항상 곁에"는 비용 2배·노이즈·역할 중복. 차별화 가치는 회의적 검수자. 둘 다 필요하면 `pair`로 옵트인 |
| **트리거** | on-demand "지금 리뷰" + watch **토글**(기본 off) | 매번 필요 없음. 토글이 곧 비용 통제 스위치. 긴/위험 작업에만 ON |
| **spec** | **필수** | direction drift는 spec 대비 판단이 필수. execution drift도 기준이 있어야 명확 |
| **task override** | 현재 task capsule의 구체 지시가 기본 spec보다 우선 | 출력 포맷, severity 체계, 리뷰 lens, 파일 범위, verify 명령이 task에 명시되면 그 task에서는 override로 인정. 형식 차이만으로 drift 기록 금지 |
| **model/CLI** | **사용자 선택** (claude/codex/gemini) | cross-model 협력이 최종 목적. executor=Claude / watcher=Codex 같은 조합 자유 |
| **표면** | 전용 `/watch` 스킬 (`/tm` 기본 유지, `/tm-op pair`는 one-shot alias) | watch는 켜고/끄는 지속 모드라 one-shot 전략(`/tm-op`)에 안 맞음 |

### 컨텍스트 폭발 방지 (핵심)

문제: 계속 살아있는 watcher pane에 매번 transcript를 먹이면 watcher 컨텍스트가 무한 증가하고,
**감시자가 감시 대상과 똑같이 drift**한다.

해법: watcher = "기억하는 동료"가 아니라 **"매번 새 눈으로 보는 검수자"**.
- 매 체크 입력 상한 고정: `spec + watched agent의 최근 delta(collect --lines N)`만. 전체 히스토리 절대 안 먹임.
- 체크 사이 watcher 누적 리셋:
  - **(MVP) pane hard-restart 후 체크** — 데몬 작업 없이 fresh context 확보
  - **(Phase 2) headless one-shot** — 체크마다 spawn→보고→종료

## 3. `/watch` 스킬 표면

```
/watch review [agent]            # on-demand 단발 stateless 체크 (기본: 모든 worker)
/watch on [agent] [--every 300]  # 지속 모드 (Phase 2 데몬 interval)
/watch off                       # 지속 중지
/watch status                    # 현재 watch 설정 + 최근 drift 이력 요약
```

공통 플래그:
- `--stance critic|advisor|pair` (기본 `critic`)
- `--cli claude|codex|gemini` `--model <m>` (watcher 모델 선택)
- `--spec <text|@path>` (팀 spec이 없을 때 직접 지정; 경로면 watcher가 매 사이클 live read)

명령 관계:
- `/tm` = 기본 fan-out 디스패치 (변경 없음)
- `/tm-op pair` = **one-shot** 페어 라운드 alias (한 번만 반박/보조)
- `/watch` = **지속/토글** 오버사이트 전용 (핵심 신규)

구현물: `.claude/commands/watch.md` + Codex IME용 `.codex/prompts/watch.md` shim 한 쌍.

## 4. drift 발견 저장 (item 4)

- **즉시 행동용**: 리더 inbox(`tm-agent msg send` → leader). 휘발성.
- **이력/추적용**: `board.jsonl` 패턴 재사용, 한 줄씩 누적:
  ```json
  {"ts": "...", "agent": "executor", "drift_type": "execution|direction", "severity": "...", "finding": "...", "spec_clause": "..."}
  ```
  → `/watch status`가 최근 이력 요약, "이 세션 drift 횟수" 추적 가능.
- **위치 주의**: `~/.term-mesh/results/<team>/`는 데몬이 24h 후 prune → 이력은 **비휘발 위치**
  (worktree의 `.xm/` 등)에 둔다.

## 5. term-mesh primitive 매핑

| 필요 동작 | 기존 자산 |
|-----------|-----------|
| watched agent 최근 출력 읽기 | `tm-agent collect --lines N` / `tm-agent read <agent>` |
| 리더에게만 보고 | `tm-agent msg send` (절대 `--to <agent>` 아님) |
| spec verbatim 주입 | `AgentRunbookService.composeInstructions(customInstructions:)` → `## Team Custom Instructions` (digest 모드에도 verbatim 생존) |
| watcher role 정의 | runbook 4-레지스트리 정합 (아래 Phase 0) |
| 주기 트리거 (Phase 2) | `tokio::time::interval` (`term-meshd/src/main.rs`, `pane_tracker.rs:34` 선례) |
| stateless fresh context | pane hard-restart (MVP) / headless one-shot (Phase 2) |

## 6. 단계별 계획

### Phase 0 — watcher role 토대 (원안 플랜)
watcher를 first-class role로 등록 + 팀 생성 시 spec 주입. 데몬 변경 없음.
- `.agent-runbooks/watcher.md` 신규 (런북: read-via-collect, 리더 전용 보고, execution/direction 구분, 이상 없으면 한 줄 OK)
- role 4-레지스트리 정합: Rust `builtin_runbook_roles()`(`tm_agent.rs`), Swift `builtInRoleNames`
  (`AgentRunbookService.swift`), GUI `builtInPresets`(`AgentRolePreset.swift`), 런북 md
- CLI `--spec` → watcher 항목에만 `custom_instructions` 부착; 핸들러(`v2TeamCreate`/`asyncTeamCreate`)에서
  watcher만 `composeInstructions(customInstructions: spec)` 미리 합성 (GUI `TermMeshApp.swift:211-229` 패턴 재사용)
- GUI: watcher 프리셋 추가 + custom-instructions 박스 라벨 "Watcher Spec"

### Phase 1 — stateless 체크 + on-demand + 스킬
- `/watch review` = pane hard-restart → `spec + collect --lines N delta` 주입 → 리더 보고
- `--stance` 3종 (런북 변형 또는 프롬프트 lens)
- `--cli`/`--model` 선택
- drift 이력 `board.jsonl` 기록 + `/watch status`
- `.claude/commands/watch.md` + `.codex/prompts/watch.md`

### Phase 2 — 지속 watch (자율)
- `/watch on/off` 토글
- `term-meshd` `tokio::time::interval` 기반 주기 트리거 (execution 자주 / direction 가끔)
- headless one-shot watcher (pane 점유 없이)
- 최종 목적인 **자율 cross-model 협력**이 여기서 완성

## 7. 운영 교훈 — 2026-05-20 false drift

사례: `/watch on reviewer`에 reviewer 페르소나 spec(`P0-P3 + VERDICT`)을 걸어둔 상태에서,
리더가 보안 리뷰 task에 `[SEVERITY]` 형식을 명시했다. watcher가 기본 spec의 출력 형식을
현재 task 지시보다 강하게 해석하면서 16건의 false drift를 기록했다.

교훈: watcher spec는 지속적인 기본 계약이고, task capsule은 현재 작업의 구체 계약이다.
둘이 충돌할 때는 task capsule의 구체 지시가 우선한다. 특히 출력 포맷, severity taxonomy,
리뷰 lens, 파일 범위, verify 명령은 task-format override로 인정해야 한다. watcher는 형식
차이만으로 drift를 기록하지 말고, task override를 따른 결과가 spec의 핵심 안전/스코프 계약과
양립 가능한지 판단한다.

문서화 원칙: 권장 spec 템플릿에는 `Task override`와 `Do not count as drift` 항목을 포함한다.
예: reviewer 기본 spec가 `P0-P3 + VERDICT`를 요구하더라도 security-lens task가 `[SEVERITY]`
형식을 요구하면, 그 형식 차이는 drift가 아니다. drift는 override를 무시했거나, override 범위를
넘어 오류 은폐, scope escape, 금지된 side effect 같은 핵심 계약을 깼을 때만 기록한다.

## 8. 미해결 / 추후 결정
- 이력 비휘발 저장 정확한 경로 (worktree `.xm/` vs app-support)
- `pair` stance에서 critic/advisor를 한 에이전트가 겸하는지 vs 2-pane 분리
- continuous 모드의 기본 interval, execution:direction 점검 비율
- watcher가 제안한 코스 교정을 리더가 자동 적용할지 vs 항상 사람 승인
