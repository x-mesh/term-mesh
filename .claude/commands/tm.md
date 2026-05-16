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
| `--no-decompose` | false | Step 1.5 decomposition을 건너뛰고 v1 same-instruction-to-all 동작으로 회귀 (opt-out) |

```
/tm "instruction"
/tm "instruction" --timeout 300
/tm "instruction" --ensure reviewer,security
/tm "instruction" --no-decompose
```

**금지 옵션**: `--mode`, `--agents N`, `--rounds`, `--decompose` — 이 커맨드 범위 밖. (`--decompose`는 decompose가 새 기본값이므로 명시적 affirmation 불필요 — 일관된 거부로 처리.)

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
- idle 에이전트 목록 확인 후 Step 1.5 진행.

### Step 1.5 — Instruction decomposition

**DECOMPOSE_MODE state machine** (determined at Step 1.5 entry):

- `off` — User passed `--no-decompose`. Skip Step 1.5 entirely. Step 2 sends original `$INSTR` to all idle agents (v1 behavior). Step 4 uses `collect --headers` + homogeneous synthesis ([충돌] = "전원 동의 / 이견").
- `on` — Template T1-T8 matched. Leader emits a 2-4 line decomposition preview, then Step 2 dispatches N heterogeneous sub-tasks via the matched dispatch plan. Step 4 uses `reports --summary` + heterogeneous synthesis ([충돌] = "독립 완료" default).
- `fallback` — No template matched OR non-decomposable heuristic hit. Leader emits 1-line Note `[plan] N개 동일 instruction fan-out — 분해 패턴 미일치, 폴백 적용`. Step 2 sends original `$INSTR` to all (same as `off` but with the explicit note). Step 4 uses `collect --headers`.

---

> **When to apply:** Before Step 2 delegate loop. If a template matches, replace the
> single `$INSTR` fan-out with N heterogeneous sub-tasks (different instruction per agent).
> If no template matches, skip this step and proceed to Step 2 with the original
> instruction (fallback = v1 same-instruction-to-all behavior).
>
> **Read mode for Step 4:** Heterogeneous sub-task dispatch always triggers
> `reports --summary` (T1 이종 경로) — NOT `collect --headers`.

---

#### Part A — Keyword / pattern template library

Match order: T1 → T7 (specific first), T8 last (catch-all). First match wins.

---

##### T1 — PR 리뷰 / 감사

**TRIGGER:**
- Keywords: `PR` or `pull request` + one of `review`, `audit`, `보안`, `security`, `코드 리뷰`
- Regex: `/(PR|pull.?request).*(review|audit|보안|security|코드.?리뷰)|(review|audit).*(PR|pull.?request)/i`

**SUB-TASKS:**
- `security`: Audit the PR diff for CWE/OWASP top-10 vulnerabilities and unsafe input handling
- `reviewer`: Review code quality — SOLID, anti-patterns, naming, dead code, test coverage gaps
- `tester`: Identify missing test cases; assess smoke test coverage for changed files
- `explorer`: Map cross-module impact — callers and dependents affected by changed APIs

**COVERAGE:** security · code-quality · testing · impact-surface

---

##### T2 — 성능 최적화

**TRIGGER:**
- Keywords: `성능 최적화`, `performance optim`, `느려`, `느린`, `slow`, `latency`, `bottleneck`
- Regex: `/성능\s*최적화|performance\s*optim|slow|latency|bottleneck|느려|느린/i`

**SUB-TASKS:**
- `backend`: Profile the target module's hot paths; identify top-3 CPU/memory bottlenecks
- `reviewer`: Check current implementation for complexity anti-patterns (N+1, eager load, unbounded loops)
- `tester`: Define a benchmark harness spec with baseline metrics and target thresholds
- `architect`: Evaluate caching, async, and batching alternatives for the identified bottlenecks

**COVERAGE:** profiling · code-review · benchmarking · architecture

---

##### T3 — 기능 구현

**TRIGGER:**
- Keywords: `구현`, `implement`, `기능 추가`, `add feature`, `만들어`, `만들기`, `추가`
- Regex: `/구현|implement|기능\s*추가|add\s*feature|만들어|만들기/i`
- Guard: exclude if instruction also matches T1 (PR context) or T4 (bug/crash)

**SUB-TASKS:**
- `planner`: Decompose the feature into independent tasks with dependency ordering and acceptance criteria
- `architect`: Define module boundary, data model delta, and public interface contract
- `executor`: Draft implementation stub with key TODOs and decision-point comments
- `tester`: List unit + integration test cases covering happy path and top-3 edge cases
- `writer`: List required CHANGELOG entry and any doc page updates

**COVERAGE:** planning · architecture · implementation · testing · docs

---

##### T4 — 버그 디버그

**TRIGGER:**
- Keywords: `디버그`, `debug`, `버그`, `bug`, `crash`, `fix`, `오류`, `error`
- Regex: `/디버그|debug|버그|bug\s*fix|fix.*crash|crash|오류/i`
- Guard: if also matches T1 (PR context), prefer T1

**SUB-TASKS:**
- `explorer`: Locate all call sites of the failing code path and recent changes to them
- `debugger`: Perform root-cause analysis — identify the invariant violation and failure path
- `tester`: Design a regression test that catches this bug before it reaches production
- `reviewer`: Check sibling modules for the same bug pattern (copy-paste regression risk)

**COVERAGE:** code-location · root-cause · regression · pattern-spread

---

##### T5 — 시스템 설계

**TRIGGER:**
- Keywords: `설계`, `design`, `아키텍처`, `architecture`, `ADR`
- Regex: `/설계|design|아키텍처|architecture|ADR/i`
- Guard: exclude if also matches T1 (PR), T2 (perf), T3 (feature impl), T4 (bug)

**SUB-TASKS:**
- `architect`: Write an ADR — context, options table, trade-offs, and recommended choice
- `planner`: Define implementation phases with milestones and cross-team dependency map
- `reviewer`: Challenge the design for scalability, backward-compatibility, and operational risks
- `security`: Identify threat-surface changes and required auth/authz controls

**COVERAGE:** architecture · planning · review · security

---

##### T6 — 문서 정리

**TRIGGER:**
- Keywords: `문서 정리`, `문서 업데이트`, `docs update`, `docs cleanup`, `README`
- Regex: `/문서\s*(정리|업데이트)|docs?\s*(update|cleanup|audit)|README/i`

**SUB-TASKS:**
- `writer`: Audit existing docs for staleness, broken commands, and gaps; produce a section-level diff plan
- `reviewer`: Identify undocumented public APIs and config options added since the last release
- `explorer`: List code changes since the last doc update to surface missing documentation targets

**COVERAGE:** docs-quality · api-coverage · change-tracking

---

##### T7 — 보안 점검

**TRIGGER:**
- Keywords: `보안 점검`, `security scan`, `security audit`, `취약점`, `vulnerability`, `threat model`
- Regex: `/보안\s*(점검|감사|스캔)|security\s*(check|scan|audit|review|threat)|취약점|vulnerability/i`
- Guard: if also matches T1 (PR context), prefer T1

**SUB-TASKS:**
- `security`: Build a threat model — entry points, trust boundaries, data flows, CWE mapping
- `reviewer`: Audit auth/authz flow for privilege escalation and session management issues
- `tester`: Design penetration test scenarios for the top-3 identified threat vectors
- `explorer`: Map external input surfaces and third-party dependency versions for CVE exposure

**COVERAGE:** threat-modeling · auth-review · pen-testing · dependency-surface

---

##### T8 — 범용 정리/점검 (catch-all)

**TRIGGER (lowest priority — apply only when T1–T7 all miss):**
- Keywords: `정리`, `점검`, `cleanup`, `health check`, `housekeeping`
- Regex: `/정리|점검|cleanup|health.?check|housekeeping/i`

**SUB-TASKS:**
- `explorer`: Survey the target area — dead code, stale imports, unused exports, large files
- `reviewer`: Assess code quality — duplication, cyclomatic complexity, convention violations
- `tester`: Report test coverage ratios and list untested critical paths

**COVERAGE:** code-health · quality · test-coverage

---

#### Part B — Fallback policy

When NO template (T1–T8) matches the user instruction:

1. Leader emits a 1-line plan before Step 2:
   ```
   [plan] N개 동일 instruction fan-out — 분해 패턴 미일치, 폴백 적용
   ```
2. Proceed to Step 2 with the **original `$INSTR`** sent identically to all idle agents (v1 behavior — no change).
3. Step 4 synthesis uses the **homogeneous path**: `collect --headers` (not `reports --summary`), and `[충돌]` uses "전원 동의 / 이견" framing instead of "독립 완료".

**Non-decomposable instruction heuristics (always fallback regardless of keyword matches):**
- Token count < 3 AND no file/module reference
- Matches pure-ping pattern: `/^(hello|hi|ping|status|test|ok)\??$/i`
- Single-entity lookup: `/^(what|where|who)\s+(is|are)\s+\w+\??$/i`
- No verb beyond simple interrogative

---

#### Part C — Determinism guarantee

| Path | Deterministic? | Notes |
|------|---------------|-------|
| Template match T1–T8 | **Yes** — same input → same role assignments | Regex/keyword rules are pure functions |
| Fallback fan-out | **Yes** — same input → same instruction to all idle agents | Role list varies only with team composition |
| LLM fallback (Phase C) | **No** — probabilistic | Must emit `[plan] LLM 분해 — 비결정론적, 세션마다 달라질 수 있음` |

**board.jsonl caching placeholder (Phase C):**
```
Cache file: ~/.term-mesh/boards/<team>/decompose-cache.jsonl
Entry:      { "hash": "<sha256(instruction)[:12]>", "template": "T3", "subtasks": [...] }
On hit:     skip template matching, use cached sub-task list directly
```
Implementation deferred to Phase C — noted here for Phase B handoff.

---

#### Part D — 3 worked examples

##### D1 — T1: PR 보안 리뷰

**INPUT:** `/tm "feature/auth PR 보안 리뷰"`

**MATCHED TEMPLATE:** T1 (keywords: "PR" + "보안 리뷰")
Idle agents assumed: security, reviewer, tester, explorer

**DISPATCH PLAN (Step 2 replacement — single Bash call):**
```bash
tm-agent delegate security "feature/auth PR 보안 리뷰 — CWE/OWASP top-10 취약점 및 unsafe input handling 감사" &
tm-agent delegate reviewer "feature/auth PR 코드 품질 리뷰 — SOLID, anti-pattern, naming, dead code, test 커버리지 갭 점검" &
tm-agent delegate tester "feature/auth PR 변경 파일 기준 누락된 테스트 케이스 목록 + 스모크 테스트 커버리지 평가" &
tm-agent delegate explorer "feature/auth PR 변경 API의 cross-module 영향 범위 — 호출자/의존 모듈 목록 출력" &
wait
```

**Step 4 synthesis mode:** `reports --summary` (이종 sub-task N=4) · **Expected [충돌]:** `독립 완료`

---

##### D2 — T3: 기능 구현

**INPUT:** `/tm "Settings UI에 darkMode 토글 추가 구현"`

**MATCHED TEMPLATE:** T3 (keyword: "구현")
Idle agents assumed: planner, architect, executor, tester, writer

**DISPATCH PLAN (Step 2 replacement — single Bash call):**
```bash
tm-agent delegate planner "Settings UI darkMode 토글 기능을 독립 구현 태스크로 분해하고 의존성 순서 및 완료 기준 정의" &
tm-agent delegate architect "darkMode 토글의 모듈 경계, UserDefaults 스키마 변경, SwiftUI 공개 인터페이스 계약 정의" &
tm-agent delegate executor "darkMode 토글 구현 스텁 초안 — 핵심 TODO 및 결정 포인트 주석 포함" &
tm-agent delegate tester "darkMode 토글 단위+통합 테스트 케이스 목록 — happy path + edge case (light→dark→light, 시스템 설정 동기화)" &
tm-agent delegate writer "darkMode 토글 CHANGELOG 엔트리 초안 및 변경 필요한 README/docs 항목 목록" &
wait
```

**Step 4 synthesis mode:** `reports --summary` (이종 sub-task N=5) · **Expected [충돌]:** `독립 완료`

---

##### D3 — T4: 버그 디버그

**INPUT:** `/tm "daemon JSON-RPC 파싱 crash 디버그"`

**MATCHED TEMPLATE:** T4 (keywords: "crash" + "디버그")
Idle agents assumed: explorer, debugger, tester, reviewer

**DISPATCH PLAN (Step 2 replacement — single Bash call):**
```bash
tm-agent delegate explorer "daemon JSON-RPC 파싱 crash 관련 코드 위치 탐색 — 실패 경로 call site와 최근 변경 파일 목록" &
tm-agent delegate debugger "daemon JSON-RPC 파싱 crash 근본 원인 분석 — 불변 조건 위반 지점과 실패 경로 특정" &
tm-agent delegate tester "daemon JSON-RPC 파싱 crash 회귀 테스트 설계 — 최소 재현 입력 정의 (malformed JSON, truncated frame, empty payload)" &
tm-agent delegate reviewer "동일 JSON-RPC 파싱 패턴을 사용하는 형제 모듈에서 같은 버그 패턴 존재 여부 확인" &
wait
```

**Step 4 synthesis mode:** `reports --summary` (이종 sub-task N=4) · **Expected [충돌]:** `독립 완료` — 또는 `병목: debugger BLOCKED 시 tester 대기`

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

---

### Example 3 — auto-decompose (T1 매칭)

```
/tm "feature/auth PR 보안 리뷰"
```

DECOMPOSE_MODE=`on`, T1 matched (keywords: "PR" + "보안 리뷰"). Leader emits decomposition preview:

```
[plan] T1 PR 리뷰 — security/reviewer/tester/explorer 분담 (4 sub-tasks)
```

Step 2 dispatches heterogeneous sub-tasks (per D1 above). Step 4 synthesis uses `reports --summary`.

```
[결론]  4/4 DONE — Security: CWE-79 XSS 1건(P0) 발견.
[충돌]  독립 완료
[다음]  security 에이전트에 XSS 패치 위임.
```

---

### Example 4 — explicit opt-out (`--no-decompose`)

```
/tm "feature/auth PR 보안 리뷰" --no-decompose
```

DECOMPOSE_MODE=`off`, Step 1.5 skipped. All idle agents receive the identical original instruction (v1 behavior). Step 4 synthesis uses `collect --headers`.

```
[결론]  Auth PR에서 force-unwrap 3곳 + token 평문 로깅 확인.
[충돌]  executor: DEBUG guard 충분 / security: Release 심볼 잔존 → security 채택.
[다음]  security에 패치 위임.
```

---

### Example 5 — fallback (template miss)

```
/tm "hello there"
```

Non-decomposable heuristic match (pure-ping pattern). DECOMPOSE_MODE=`fallback`. Leader emits:

```
[plan] 2개 동일 instruction fan-out — 분해 패턴 미일치, 폴백 적용
```

Step 2 sends original instruction to all idle agents. Step 4 uses `collect --headers`.

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
