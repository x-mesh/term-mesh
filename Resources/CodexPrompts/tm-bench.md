---
description: "term-mesh agent team communication benchmark — Codex leader wrapper for scripts/bench-agent.py"
---

# /tm-bench — Codex Agent Team Benchmark

User provided: $ARGUMENTS

Run automated benchmarks on the term-mesh agent team communication system.
Measures RPC infrastructure latency and end-to-end agent response times across
**pane vs headless** infrastructure and **terminal vs LLM leader** modes.
Results are saved to `~/.term-mesh/benchmarks/YYYY-MM-DDTHH-MM-SS.json` and compared
with previous runs automatically.

All benchmark runs go through `python3 scripts/bench-agent.py`. Do not use Codex native
sub-agents for term-mesh teams.

## Empty input

If `$ARGUMENTS` is empty, show the menu and stop:

```text
서브커맨드:
  agent              에이전트 통신 벤치마크 (기본: pane + terminal leader E2E)
  agent --pane       pane 인프라
  agent --headless   headless 인프라
  agent --llm        LLM leader E2E (--claude-leader 로 새 팀 생성)
  agent --terminal   terminal leader E2E (기존 팀 사용)
  agent --rpc        RPC latency 만 측정
  agent --e2e        E2E 통신 만 측정
  agent --repeat N   N회 반복
  agent --note "..." 변경 메모 첨부
  history            최근 10개 결과 표
  compare A B        두 실행 비교 (타임스탬프 prefix)

예:
  /tm-bench agent --e2e
  /tm-bench agent --pane --repeat 5 --note "렌더링 ON"
  /tm-bench history
  /tm-bench compare 2026-05-23T10 2026-05-23T14
```

## Routing

Parse the first word of `$ARGUMENTS` as the subcommand, then build the `bench-agent.py`
invocation:

| Input | Command |
|-------|---------|
| `agent` (no flags) | `python3 scripts/bench-agent.py --e2e-only --mode pane --leader terminal` |
| `agent --pane` | `python3 scripts/bench-agent.py --mode pane` |
| `agent --headless` | `python3 scripts/bench-agent.py --mode headless` |
| `agent --llm` | `python3 scripts/bench-agent.py --leader llm` |
| `agent --terminal` | `python3 scripts/bench-agent.py --leader terminal --mode pane` |
| `agent --rpc` | `python3 scripts/bench-agent.py --rpc-only --mode pane --leader terminal` |
| `agent --e2e` | `python3 scripts/bench-agent.py --e2e-only --mode pane --leader terminal` |
| `history` | `python3 scripts/bench-agent.py --history` |
| `compare A B` | `python3 scripts/bench-agent.py --compare A B` |

### Argument parsing precedence (for `agent`)

1. **Explicit `--repeat N` wins.** If present, use it and do not scan for bare numbers.
2. **Otherwise extract the first bare integer** (e.g. `agent 5` → `--repeat 5`).
3. **Map mode/leader flags:** `--pane`→`--mode pane`, `--headless`→`--mode headless`,
   `--llm`→`--leader llm`, `--terminal`→`--leader terminal`, `--rpc`→`--rpc-only`,
   `--e2e`→`--e2e-only`.
4. **Pass through `--note "..."`** unchanged.

## Execution

1. Run `tm-agent status` first. For E2E modes that reuse an existing team
   (`--e2e`, `--terminal`, bare `agent`), if no team exists, ask the user to run:
   ```bash
   tm-agent create 3 --adopt
   ```
2. Run the mapped `python3 scripts/bench-agent.py ...` command via shell.
3. Show the output to the user.
4. A comparison delta against the previous run is printed automatically when one exists.
