# /tm — 팀 일괄 dispatch 커맨드

## Goal

하나의 instruction을 활성 팀의 **모든 idle 에이전트에게 동시에** delegate하고, 결과를 3줄 synthesis로 수렴한다.

**L2 intensity**: 팀이 이미 구성되어 있을 때만 유효. 단발 병렬 dispatch — rounds 없음, 자동 합성 포함.

## When to use

> **팀 생성·상태·태스크 보드 관리는 `/team` 또는 `tm-agent <subcommand>` 직접 사용.** 이 커맨드는 fan-out workflow에 집중. 다른 tm-agent 기능은 `.claude/commands/team.md` 참고.

| 상황 | 커맨드 |
|------|--------|
| 모든 에이전트가 동시에 같은 목표를 보고 각자 역할 관점으로 답해야 할 때 | `/tm` |
| 라운드 기반 정제, 토론, 파이프라인이 필요할 때 | `/tm-op refine|debate|chain` |
| 에이전트 1명에게만 작업 위임 | `tm-agent delegate <agent>` |
| 팀 구성 (add/remove/swap) | `/team add <role>` |
| 팀 생성·상태·태스크 관리 | `/team` |
| dispatch 전 role 사전 보장 | `/tm --ensure <roles> ...` |

`/tm`은 `/tm-op`의 경량 진입점 — rounds 없고, 전략 선택 없고, 1회 dispatch 후 즉시 synthesis.

## Empty input

If `$ARGUMENTS` is empty (사용자가 `/tm`만 입력), do NOT run the workflow. Instead print:

```
이 명령은 모든 idle agent를 동시 동원하고 결과를 종합합니다.

  /tm "review src/auth.ts"
  /tm "monolith vs microservices" --timeout 120
  /tm --ensure reviewer,security "이 PR 보안 리뷰"

내부 단계에서 호출하는 low-level 명령들 (직접 사용 가능):

  /team status               누가 idle인가
  /team delegate <a> "..."   특정 한 명에게
  /team wait                 모두 완료까지 대기
  /team collect --headers    헤더만 모아 보기
  /team task clear           끝난 태스크 정리

자세히: .claude/commands/tm.md / .claude/commands/team.md
```

Do NOT proceed to Workflow.

## Arguments

User provided: $ARGUMENTS

첫 번째 토큰은 instruction (따옴표 권장):

```
/tm "instruction"
/tm "instruction" --timeout 300
```

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `"instruction"` | (필수) | 모든 에이전트에게 전달되는 단일 instruction |
| `--timeout <s>` | 300 | `tm-agent wait` 타임아웃 (초) |
| `--ensure <roles>` | (없음) | 쉼표 구분 role 목록 — 없는 role은 fan-out 전 자동 attach |

```
/tm "instruction"
/tm "instruction" --timeout 300
/tm "instruction" --ensure reviewer,security
```

**금지 옵션**: `--mode`, `--agents N`, `--rounds` — 이 커맨드 범위 밖.

## Workflow

`$ARGUMENTS`에서 instruction과 `--timeout` 파싱 후 아래 5단계 순서 엄수.

### Step 1 — 팀 상태 확인 + --ensure 처리 (= /team status)

```bash
tm-agent status  # = /team status
```

**`--ensure` 처리 (있을 때만):**

`$ARGUMENTS`에서 `--ensure <roles>` 파싱 후, 쉼표 구분 각 role에 대해:
- `tm-agent status`에 해당 type의 에이전트가 존재하면 → `SKIPPED <role> (already present)`
- 없으면 → `tm-agent attach <role>` 실행 → `ENSURED: <role> (added)`

```bash
# 예: /tm "review auth.ts" --ensure reviewer,security
# → ENSURED: reviewer (added), security (already present)
```

`--ensure` 처리 후 status를 다시 읽어 idle 에이전트 목록 갱신.

**Missing-role guard (--ensure 없을 때만):**

instruction에 아래 heuristic이 일치하면, 해당 role이 팀에 없는지 확인:
- "security review", "security audit", "vulnerability" → `security`
- "design review", "UI review", "UX review" → `reviewer`
- "code review", "review the code" → `reviewer`

해당 role이 팀에 없고 `--ensure`도 주어지지 않았으면, fan-out 전 경고 출력:

```
Note: <role> agent not in team. Run `/team add <role>` first, or rerun with `/tm --ensure <role> ...`
```

그 다음 가용 에이전트로 fan-out 계속 진행. 자동 attach 하지 않는다.

**상태 확인:**

- `in_progress` 태스크가 있는 에이전트가 있으면 → **REJECT**: "team busy; run `tm-agent task clear` first"
- idle 에이전트가 0명이면 → **REJECT**: "no idle agents available"
- idle 에이전트 목록 확인 후 Step 2 진행.

### Step 2 — Sequential per-agent delegate (= /team delegate per agent, mixed-CLI safe)

Instructions are passed to `tm-agent delegate` as a single argument (RPC arg vector, no shell expansion). Wrap in double-quotes; do NOT use unquoted `$VAR` substitution.

All `tm-agent delegate &` + `wait` MUST live inside ONE Bash tool call. Spawning across multiple Bash calls breaks parallelism because background processes belong to different shells.

```bash
# double-quote + INSTR variable form (single-quote-safe)
INSTR="<the user's instruction>"
tm-agent delegate <agent1> "$INSTR" &  # = /team delegate <agent> "$INSTR"
tm-agent delegate <agent2> "$INSTR" &
tm-agent delegate <agent3> "$INSTR" &
# ... 나머지 idle 에이전트
wait
```

> **주의**: `broadcast` + `tm-agent claim` 패턴은 claude-CLI 전용이며 codex/gemini/kiro 패널에서는 silent no-op. 반드시 `delegate` 개별 발행.

### Step 3 — Sync barrier (= /team wait)

```bash
tm-agent wait --timeout <timeout> --mode report  # = /team wait --timeout <n> --mode report
```

timeout 만료 시에도 Step 4로 진행 (부분 결과 수렴).

### Step 4 — Read & synthesize (= /team collect + leader synthesis)

**(a) 헤더 수집 — 3-tier 읽기 룰**

모드에 따라 T1 → T2 → T3 순서로 필요한 만큼만 읽는다.

**T1 (항상, ~1,200 tok):**

- **균질 fan-out** (동일 instruction → 모든 에이전트): `tm-agent collect --headers`
- **이종 sub-task** (N≥6, 서로 다른 instruction): `tm-agent reports --summary` (~2,200 tok) — 개별 FULL_REPORT N개 합산(~3,400–5,200 tok)보다 우월

```bash
# 균질 fan-out
tm-agent collect --headers

# 이종 sub-task (N≥6)
tm-agent reports --summary
```

**T2 (조건부, ~500 tok/agent):** BLOCKED 또는 NEEDS_REVIEW agent에 한해 해당 task 보고서 읽기:

```bash
cat ~/.term-mesh/results/<team>/<task_id>.md
```

**T3 (예외, ~2,000 tok/agent):** 교차모순 탐지 시만 — 충돌 당사자 FULL_REPORT만 읽기. 전체 읽기 금지(Anti-pattern 5).

> **절대 금지**: `~/.term-mesh/results/<team>/<agent>-reply.md` 직접 읽기 — 동일 에이전트에 serial delegate가 쌓이면 last-writer-wins race 발생, 잘못된 태스크 결과 반환.

**(b) 3줄 synthesis (필수)**

수집 결과를 바탕으로 **정확히 아래 형식**으로 요약:

```
[결론]  K/N DONE + severity-tier 최고-영향 발견 1문장
[충돌]  교차모순 | 병목 | 미해결 게이트 | "독립 완료"
[다음]  P0→P5 결정 트리 첫 비어있지 않은 버킷 액션
```

**[결론] 압축 룰** — `K/N DONE` 진척 분수 + severity-tier 최고-영향 발견 1문장. Tier 우선순위: `Blocker → Security → Cross-cutting → Feature → Net achievement`. 손실 허용 = 개별 세부 발견; 손실 불가 = K/N 카운트 + 최고 위험.

**[충돌] 3종 후보** (이종 sub-task 모드에서 "이견" 개념 부적용 — 교체):
- **교차모순**: 한 agent 변경이 다른 agent 전제를 무효화 — NEXT 필드 파일 경로 중복으로 탐지
- **병목**: BLOCKED agent + downstream 의존 존재
- **미해결 게이트**: NEEDS_REVIEW agent 존재
- 셋 다 없으면 → `독립 완료`

**[다음] 결정 트리 P0→P5** — 첫 번째 비어있지 않은 버킷이 NEXT:
- P0: BLOCKED unblock
- P1: NEEDS_REVIEW review
- P2: 교차모순 우선 결정
- P3: 가장 많은 downstream unlock
- P4: security > perf > feat > docs
- P5: PR/release

이후 각 에이전트의 FULL_REPORT 경로 나열:

```
FULL_REPORTS:
  <agent1>: ~/.term-mesh/results/<team>/<task_id>.md
  <agent2>: ~/.term-mesh/results/<team>/<task_id>.md
```

**(c) Truncation 감지**

아래 신뢰도 순으로 truncation 여부를 판단한다:
- **[확실]** FULL_REPORT 필드 값이 `n/a`가 아님 → agent 선언 경로 사용
- **[확실]** content 끝이 `...` → truncate 마커
- **[높음]** NEXT 또는 VERIFY 필드 문장이 중간에 끊김

truncation 확인 시 T2/T3 단계로 진입한다.

## Anti-patterns

1. **`<agent>-reply.md` 직접 읽기 금지** — 반드시 `<task_id>.md` 사용. 동일 에이전트에 serial delegate가 쌓이면 `agent-reply.md`는 마지막 결과만 남음 (last-writer-wins, daemon/term-mesh-cli/src/tm_agent.rs:5912 atomic-write). task_id 기반 파일만 신뢰할 수 있음.
2. **`/tm-op`과 동시 실행 금지** — 두 커맨드 모두 팀의 태스크 어사이니를 경쟁적으로 사용. 한 번에 하나만 실행.
3. **`--agents N` 플래그 노출 및 수용 금지** — 팀 크기는 `tm-agent create N`으로 이미 결정됨. 런타임 agent 수 변경은 이 커맨드 범위 밖.
4. **3줄 synthesis 생략 또는 축약 금지** — `[충돌]` 라인은 "독립 완료"여도 반드시 출력. synthesis 없는 raw collect 결과 출력은 이 커맨드의 존재 이유를 없앰.
5. **이종 sub-task 모드에서 FULL_REPORT 전체 읽기 금지** — N≥6 이종 모드에서 모든 FULL_REPORT를 읽으면 ~3,400–5,200 tok 소비. `reports --summary`(~2,200 tok)로 충분; T3(FULL_REPORT)는 교차모순 탐지 시 당사자 파일만 읽는다.

## Examples

### Example 1 — 코드 보안·성능 리뷰

```
/tm "review Sources/Auth.swift for security and performance issues"
```

Dispatch: (per Workflow step 2 — `INSTR="review Sources/Auth.swift for security and performance issues"`, idle agents: explorer, executor, reviewer, security)

**3줄 synthesis** (Step 4b):
```
[결론]  Auth.swift에 force-unwrap 3곳 + 평문 token 로깅 1곳이 즉시 수정 필요한 취약점.
[충돌]  executor: token 로깅은 DEBUG guard 있어 무시 가능 / security: Release 빌드에도 심볼 잔존 → security 채택 (binary strip 미보장).
[다음]  security 에이전트에게 force-unwrap 3곳 패치 위임.
```

```
FULL_REPORTS:
  explorer: ~/.term-mesh/results/my-team/a1b2c3d4.md
  executor:  ~/.term-mesh/results/my-team/e5f6a7b8.md
  reviewer: ~/.term-mesh/results/my-team/c9d0e1f2.md
  security: ~/.term-mesh/results/my-team/g3h4i5j6.md
```

---

### Example 2 — 아키텍처 설계 비교

```
/tm "monolith vs microservices for our current scale — which fits better?"
```

Dispatch: (per Workflow step 2 — `INSTR="monolith vs microservices for our current scale — which fits better?"`, idle agents: architect, executor, reviewer)

**3줄 synthesis** (Step 4b):
```
[결론]  현 팀 규모(3명)와 데이터 경계 미확정 상태에서는 monolith가 적합.
[충돌]  architect: 마이크로서비스 — 확장성 선제 확보 / executor: monolith — 운영 비용 현실적 → executor 채택 (현재 배포 복잡도 우선).
[다음]  monolith + 모듈 경계 문서화 → Phase 2에서 독립 서비스 분리 계획 수립.
```

```
FULL_REPORTS:
  architect: ~/.term-mesh/results/my-team/k7l8m9n0.md
  executor:  ~/.term-mesh/results/my-team/o1p2q3r4.md
  reviewer:  ~/.term-mesh/results/my-team/s5t6u7v8.md
```

## Smoke test

PR merge 후 5분 안에 `/tm` 기본 경로가 살아있는지 확인하는 절차.

1. **Preflight** — 팀은 이미 생성되어 있어야 하며 active task는 0개, idle agent는 2명 이상이어야 한다.

```bash
tm-agent status
```

통과 조건: `active_task_id: null`인 idle agent가 2명 이상이고, 진행 중/assigned task가 없다. 남은 task가 있으면 `tm-agent task clear` 후 다시 확인한다.

2. **Trigger** — 아래 명령을 그대로 실행한다.

```bash
/tm "list 3 release-blockers" --timeout 60
```

예상 dispatch 출력은 `tm-agent delegate <agent> 'list 3 release-blockers' &` 형태의 sequential delegate 4-6라인, `wait`, `tm-agent wait --timeout 60 --mode report`, `tm-agent collect --headers` 순서다.

3. **Verify** — 화면에 header collect와 3줄 synthesis가 모두 보여야 한다.

예상 형태:

```text
AGENT      STATUS  NEXT  FULL_REPORT
architect  DONE    ...   ~/.term-mesh/results/<team>/<task_id>.md
reviewer   DONE    ...   ~/.term-mesh/results/<team>/<task_id>.md

[결론]  ...
[충돌]  전원 동의
[다음]  ...
```

PASS 기준: `[결론]` 라인이 존재하고, delegate된 agent N개의 header가 `STATUS: DONE` 또는 표의 `STATUS=DONE`으로 수집된다. FAIL이면 `tm-agent status`, `tm-agent collect --headers`, `tm-agent reports --summary`, `cat ~/.term-mesh/results/<team>/<task_id>.md` 순서로 확인한다.

## Future (v2 deferred)

다음 기능은 `/tm` v2로 연기:

- `--mode split` — LLM이 instruction을 N개 subtask로 분해 후 각자 다른 작업 (현재: distribute 전략 사용)
- `--mode race` — 동일 prompt → 독립 답변 → 투표 수렴 (현재: `/tm-op tournament` 사용)
- `--filter <role>` — 특정 역할 에이전트만 대상
- 자동 retry on BLOCKED (현재: 수동 `tm-agent task unblock`)
