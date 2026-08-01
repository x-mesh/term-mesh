---
description: "term-mesh strategy orchestration — Codex leader wrapper for tm-agent strategies"
---

# /tm-op — Codex Strategy Orchestrator

User provided: $ARGUMENTS

Use this when the team needs a structured strategy rather than a one-shot fan-out.

All operations must use `tm-agent`. Do not use Codex native sub-agents for term-mesh teams.

## Empty input

If `$ARGUMENTS` is empty, show the strategy catalog and stop:

```text
전략:
  refine      라운드 기반 발산 -> 수렴 -> 검증
  tournament  전원 경쟁 후 채택
  chain       A -> B -> C 순차 파이프라인
  review      다각도 코드 리뷰
  debate      찬반 토론 후 판정
  red-team    공격/방어로 결함 찾기
  brainstorm  아이디어 발산 및 선택
  distribute  독립 작업 분배 및 병합
  council     다자 숙의
  research    board.jsonl 기반 협동 탐색

예:
  /tm-op review --target Sources/Auth.swift
  /tm-op refine "Codex leader UX" --rounds 3
  /tm-op distribute "Sentry 이슈 6개 분석"
```

## Strategy execution

1. Run `tm-agent status` first. If no team exists, ask the user to run:
   ```bash
   tm-agent create 3 --adopt
   ```

2. Parse the first word of `$ARGUMENTS` as the strategy.

3. Use the project `tm-agent` primitives to execute the selected strategy:
   - `review`: delegate role-specific review tasks, wait, collect headers, synthesize severity-sorted findings.
   - `distribute`: split the work into independent subtasks, delegate to different idle agents, wait, merge.
   - `chain`: delegate each step only after the previous result is collected.
   - `refine`: run round-based fan-out, synthesize, then send the synthesis into the next round.
   - `tournament`: delegate the same task to multiple agents, collect answers, ask a judge/reviewer to pick.
   - `debate`: assign pro/con/arbiter roles, collect positions, then synthesize decision.
   - `red-team`: attackers find issues, defenders propose fixes, reviewer verifies.
   - `brainstorm`: collect unconstrained ideas, group, vote or rank, then summarize.
   - `council`: run multi-agent deliberation with explicit agenda and final decision.
   - `research`: use `tm-agent research <topic>` with provided flags.

4. Always wait and collect before answering:
   ```bash
   tm-agent wait --timeout <timeout> --mode report
   tm-agent collect --headers
   tm-agent reports --summary
   ```

5. Read task-specific `FULL_REPORT` files when headers show blocked/review-needed/truncated results.

6. Final output:
   - decision or findings first
   - conflicts and why one side was adopted
   - next action
   - relevant full report paths
