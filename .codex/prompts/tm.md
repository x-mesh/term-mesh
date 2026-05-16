---
description: "term-mesh fan-out — delegate one instruction to idle agents and synthesize"
---

# /tm — Codex Leader Fan-out

User provided: $ARGUMENTS

Goal: dispatch one instruction to all idle term-mesh agents, wait for reports, and return a concise synthesis.

This prompt is the Codex equivalent of the Claude `/tm` command. It must use `tm-agent`; do not use Codex sub-agents for term-mesh team work.

## Empty input

If `$ARGUMENTS` is empty, print:

```text
이 명령은 모든 idle agent를 동시 동원하고 결과를 종합합니다.

  /tm "review src/auth.ts"
  /tm "monolith vs microservices" --timeout 120
  /tm --ensure reviewer,security "이 PR 보안 리뷰"   # 없는 role 자동 추가 후 fan-out
  /tm "feature/auth PR 보안 리뷰" --no-decompose       # v1 same-instruction-to-all (opt-out)

팀 구성 변경은 /team 사용:
  /team add reviewer        reviewer 추가
  /team ensure reviewer security  없는 role만 추가
  /team status              현재 팀 상태
```

Then stop.

## Parse arguments

- Instruction: required natural language text from `$ARGUMENTS`.
- `--timeout <seconds>`: optional, default `300`.
- `--ensure <roles>`: optional, comma-separated role list — roles not yet in team are attached before fan-out.
- `--no-decompose`: optional — skip Step 1.5 decomposition and revert to v1 same-instruction-to-all behavior.

Reject unsupported flags: `--rounds`, `--agents`, `--mode`, `--decompose` (decompose is the new default; explicit affirmation flag is rejected). Use `/tm-op` for strategies.

**DECOMPOSE_MODE state machine** (evaluated at workflow Step 1.5):

- `off` — `--no-decompose` passed. Skip Step 1.5. Step 2 sends original `$INSTR` to all idle agents. Step 4 uses `collect --headers` + homogeneous synthesis ([충돌] = "전원 동의 / 이견").
- `on` — Template T1–T8 matched (see `.claude/commands/tm.md` Step 1.5 for full template library — single source of truth). Leader emits 2-4 line decomposition preview; Step 2 dispatches N heterogeneous sub-tasks. Step 4 uses `reports --summary` + heterogeneous synthesis ([충돌] = "독립 완료" default).
- `fallback` — No template matched OR non-decomposable heuristic hit (token count < 3, pure-ping, single-entity lookup). Emit `[plan] N개 동일 instruction fan-out — 분해 패턴 미일치, 폴백 적용`. Step 2 proceeds with original `$INSTR` to all agents. Step 4 uses `collect --headers`.

## Workflow

1. Check team state:
   ```bash
   tm-agent status
   ```
   If no team exists, tell the user to run `/team create 3 --adopt`.

   **`--ensure` handling (when flag is present):** For each role in the comma-separated list, check status. Skip if already present; otherwise run `tm-agent attach <role>`. Print `ENSURED: <role> (added)` or `ENSURED: <role> (already present)` per entry. Re-read status after attaching to refresh idle agent list.

   **Missing-role guard (only when `--ensure` is NOT given):** If the instruction matches a heuristic below, check whether that role is present in the team. If missing, print before fan-out and then continue with available agents — do NOT auto-attach:

   ```
   Note: <role> agent not in team. Run /team add <role> first, or rerun with /tm --ensure <role> "..."
   ```

   Heuristics:
   - "security review", "security audit", "vulnerability" → `security`
   - "design review", "UI review", "UX review" → `reviewer`
   - "code review", "review the code" → `reviewer`
   - "performance audit", "perf review" → `tester`

2. Identify idle agent names from the status output. If there are no idle agents, tell the user the team is busy and suggest:
   ```bash
   tm-agent task list
   tm-agent task clear
   ```

3. Delegate to each idle agent. Use one shell call when possible so the fan-out happens together:
   ```bash
   INSTR="<the user's instruction>"
   tm-agent delegate <agent1> "$INSTR" &
   tm-agent delegate <agent2> "$INSTR" &
   tm-agent delegate <agent3> "$INSTR" &
   wait
   ```

4. Wait for reports:
   ```bash
   tm-agent wait --timeout <timeout> --mode report
   ```

5. Collect headers — 3-tier reading rule:

   **T1 (always):**
   - Homogeneous fan-out (same instruction to all): `tm-agent collect --headers` (~1,200 tok)
   - Heterogeneous sub-task (N≥6, different instructions): `tm-agent reports --summary` (~2,200 tok) — cheaper than reading N full files (~3,400–5,200 tok)

   **T2 (conditional):** For BLOCKED or NEEDS_REVIEW agents only — read the task file:
   ```bash
   cat ~/.term-mesh/results/<team>/<task_id>.md
   ```

   **T3 (exception):** Cross-contradiction detected only — read FULL_REPORT for conflicting agents only. Do NOT read all FULL_REPORTs.

6. Truncation detection (confidence order):
   - **[certain]** FULL_REPORT field ≠ `n/a` → use agent-declared path
   - **[certain]** content ends with `...` → truncation marker
   - **[high]** NEXT or VERIFY field sentence cuts mid-word

   On truncation detected: enter T2/T3 as needed.

7. Return exactly this synthesis block:
   ```text
   [결론]  K/N DONE + severity-tier 최고-영향 발견 1문장
   [충돌]  교차모순 | 병목 | 미해결 게이트 | "독립 완료"
   [다음]  P0→P5 결정 트리 첫 비어있지 않은 버킷 액션
   ```

   **[결론]**: K/N DONE 분수 + `Blocker→Security→Cross-cutting→Feature→Net achievement` 순 최고 severity 발견.

   **[충돌] 3종 후보** (이종 sub-task 모드에서 "이견" 대신 사용):
   - 교차모순: NEXT 필드 파일 경로 중복으로 탐지
   - 병목: BLOCKED + downstream 의존
   - 미해결 게이트: NEEDS_REVIEW 존재
   - 셋 다 없으면 → `독립 완료`

   **[다음] P0→P5** — 첫 비어있지 않은 버킷: P0=BLOCKED unblock / P1=NEEDS_REVIEW review / P2=교차모순 결정 / P3=downstream unlock 최다 / P4=security>perf>feat>docs / P5=PR/release.

Then list useful `FULL_REPORT` paths.

## IME Routing Request

If the input contains an `IME ROUTING REQUEST`, treat it as a leader instruction generated by the IME box:

- `MODE: TASK` -> use `tm-agent delegate <target> '<USER_TEXT>'`, then wait and collect.
- `MODE: MESSAGE` -> use `tm-agent send <target> '<USER_TEXT>'`. If the user expects a reply, ask the target to answer through `tm-agent reply` or `tm-agent msg send`.
- `MODE: PING` -> use `tm-agent send` or `tm-agent broadcast` with an explicit request to reply, then wait/collect.
- `TARGET: @all` or `@team` -> fan out to every listed target, not only one agent name.

Keep the leader in the loop. Never report success just because the IME box delivered the request to the leader pane.
