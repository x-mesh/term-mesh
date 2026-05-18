# `/tm --decompose` 템플릿 라이브러리

> `/tm --decompose`가 명시된 경우에만 leader가 이 파일을 로드한다.
> 기본 경로(plain `/tm`)에서는 통째로 건너뛴다. tm.md 본문의 컨텍스트 비용을 줄이기 위해 분리됨.

`tm.md` Step 1.5 (Instruction decomposition) 진입 시 참조. DECOMPOSE_MODE state machine 자체는 `tm.md`에 정의.

---

## Part A — Keyword / pattern template library

Match order: T1 → T7 (specific first), T8 last (catch-all). First match wins.

---

### T1 — PR 리뷰 / 감사

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

### T2 — 성능 최적화

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

### T3 — 기능 구현

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

### T4 — 버그 디버그

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

### T5 — 시스템 설계

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

### T6 — 문서 정리

**TRIGGER:**
- Keywords: `문서 정리`, `문서 업데이트`, `docs update`, `docs cleanup`, `README`
- Regex: `/문서\s*(정리|업데이트)|docs?\s*(update|cleanup|audit)|README/i`

**SUB-TASKS:**
- `writer`: Audit existing docs for staleness, broken commands, and gaps; produce a section-level diff plan
- `reviewer`: Identify undocumented public APIs and config options added since the last release
- `explorer`: List code changes since the last doc update to surface missing documentation targets

**COVERAGE:** docs-quality · api-coverage · change-tracking

---

### T7 — 보안 점검

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

### T8 — 범용 정리/점검 (catch-all)

**TRIGGER (lowest priority — apply only when T1–T7 all miss):**
- Keywords: `정리`, `점검`, `cleanup`, `health check`, `housekeeping`
- Regex: `/정리|점검|cleanup|health.?check|housekeeping/i`

**SUB-TASKS:**
- `explorer`: Survey the target area — dead code, stale imports, unused exports, large files
- `reviewer`: Assess code quality — duplication, cyclomatic complexity, convention violations
- `tester`: Report test coverage ratios and list untested critical paths

**COVERAGE:** code-health · quality · test-coverage

---

## Part B — Fallback policy

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

## Part C — Determinism guarantee

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

## Part D — 3 worked examples

### D1 — T1: PR 보안 리뷰

**INPUT:** `/tm "feature/auth PR 보안 리뷰" --decompose`

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

### D2 — T3: 기능 구현

**INPUT:** `/tm "Settings UI에 darkMode 토글 추가 구현" --decompose`

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

### D3 — T4: 버그 디버그

**INPUT:** `/tm "daemon JSON-RPC 파싱 crash 디버그" --decompose`

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

---

## Decompose 모드 실행 예시

### --decompose + T1 매칭

```
/tm "feature/auth PR 보안 리뷰" --decompose
```

DECOMPOSE_MODE=`on` (사용자가 `--decompose` 명시), T1 matched. Leader emits decomposition preview:

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

### --decompose + template miss (fallback)

```
/tm "hello there" --decompose
```

`--decompose` 명시됨 + non-decomposable heuristic match (pure-ping pattern). DECOMPOSE_MODE=`fallback`. Leader emits:

```
[plan] 2개 동일 instruction fan-out — 분해 패턴 미일치, 폴백 적용
```

Step 2 sends original instruction to all idle agents. Step 4 uses `collect --headers`.
