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
| 팀 생성·상태·태스크 관리 | `/team` |

`/tm`은 `/tm-op`의 경량 진입점 — rounds 없고, 전략 선택 없고, 1회 dispatch 후 즉시 synthesis.

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

**금지 옵션**: `--mode`, `--agents N`, `--rounds` — 이 커맨드 범위 밖.

## Workflow

`$ARGUMENTS`에서 instruction과 `--timeout` 파싱 후 아래 5단계 순서 엄수.

### Step 1 — 팀 상태 확인

```bash
tm-agent status
```

- `in_progress` 태스크가 있는 에이전트가 있으면 → **REJECT**: "team busy; run `tm-agent task clear` first"
- idle 에이전트가 0명이면 → **REJECT**: "no idle agents available"
- idle 에이전트 목록 확인 후 Step 2 진행.

### Step 2 — Sequential per-agent delegate (mixed-CLI safe)

Instructions are passed to `tm-agent delegate` as a single argument (RPC arg vector, no shell expansion). Wrap in double-quotes; do NOT use unquoted `$VAR` substitution.

All `tm-agent delegate &` + `wait` MUST live inside ONE Bash tool call. Spawning across multiple Bash calls breaks parallelism because background processes belong to different shells.

```bash
# double-quote + INSTR variable form (single-quote-safe)
INSTR="<the user's instruction>"
tm-agent delegate <agent1> "$INSTR" &
tm-agent delegate <agent2> "$INSTR" &
tm-agent delegate <agent3> "$INSTR" &
# ... 나머지 idle 에이전트
wait
```

> **주의**: `broadcast` + `tm-agent claim` 패턴은 claude-CLI 전용이며 codex/gemini/kiro 패널에서는 silent no-op. 반드시 `delegate` 개별 발행.

### Step 3 — Sync barrier

```bash
tm-agent wait --timeout <timeout> --mode report
```

timeout 만료 시에도 Step 4로 진행 (부분 결과 수렴).

### Step 4 — Read & synthesize

**(a) 헤더 수집 및 full report 접근**

```bash
tm-agent collect --headers
```

BLOCKED 또는 NEEDS_REVIEW 에이전트는 task_id 파악 후 전체 보고서 직접 읽기:

```bash
cat ~/.term-mesh/results/<team>/<task_id>.md
```

> **절대 금지**: `~/.term-mesh/results/<team>/<agent>-reply.md` 직접 읽기 — 동일 에이전트에 serial delegate가 쌓이면 last-writer-wins race 발생, 잘못된 태스크 결과 반환.

**(b) 3줄 synthesis (필수)**

수집 결과를 바탕으로 **정확히 아래 형식**으로 요약:

```
[결론]  모든 에이전트가 수렴하는 단일 문장 — 결정/진단/핵심 발견
[충돌]  이견 에이전트명 + 주장 요약 + 채택 근거 | "전원 동의" (이견 없을 때)
[다음]  leader가 즉시 실행할 액션 한 줄
```

이후 각 에이전트의 FULL_REPORT 경로 나열:

```
FULL_REPORTS:
  <agent1>: ~/.term-mesh/results/<team>/<task_id>.md
  <agent2>: ~/.term-mesh/results/<team>/<task_id>.md
```

## Anti-patterns

1. **`<agent>-reply.md` 직접 읽기 금지** — 반드시 `<task_id>.md` 사용. 동일 에이전트에 serial delegate가 쌓이면 `agent-reply.md`는 마지막 결과만 남음 (last-writer-wins, daemon/term-mesh-cli/src/tm_agent.rs:5912 atomic-write). task_id 기반 파일만 신뢰할 수 있음.
2. **`/tm-op`과 동시 실행 금지** — 두 커맨드 모두 팀의 태스크 어사이니를 경쟁적으로 사용. 한 번에 하나만 실행.
3. **`--agents N` 플래그 노출 및 수용 금지** — 팀 크기는 `tm-agent create N`으로 이미 결정됨. 런타임 agent 수 변경은 이 커맨드 범위 밖.
4. **3줄 synthesis 생략 또는 축약 금지** — `[충돌]` 라인은 "전원 동의"여도 반드시 출력. synthesis 없는 raw collect 결과 출력은 이 커맨드의 존재 이유를 없앰.

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
