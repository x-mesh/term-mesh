# tm-bench — Agent Team Communication Benchmark

Run automated benchmarks on the term-mesh agent team communication system.
Measures RPC infrastructure latency and end-to-end agent response times.
Supports **pane vs headless** infrastructure and **terminal vs LLM leader** modes.
Results are saved as JSON and compared with previous runs to track improvements.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse `$ARGUMENTS` to determine the subcommand:

| Input | Command |
|-------|---------|
| `agent` | `python3 scripts/bench-agent.py` (interactive menu) |
| `agent --pane` | `python3 scripts/bench-agent.py --mode pane` |
| `agent --headless` | `python3 scripts/bench-agent.py --mode headless` |
| `agent --llm` | `python3 scripts/bench-agent.py --leader llm` |
| `agent --terminal` | `python3 scripts/bench-agent.py --leader terminal --mode pane` |
| `agent --rpc` | `python3 scripts/bench-agent.py --rpc-only --mode pane --leader terminal` |
| `agent --e2e` | `python3 scripts/bench-agent.py --e2e-only --mode pane --leader terminal` |
| `agent --note "..."` | append `--note "..."` to the command |
| `history` | `python3 scripts/bench-agent.py --history` |
| `compare A B` | `python3 scripts/bench-agent.py --compare A B` |

Map the first word of `$ARGUMENTS`:

- **`agent`** → Run benchmarks. Without flags → interactive menu. Map `--pane` to `--mode pane`, `--headless` to `--mode headless`, `--llm` to `--leader llm`, `--terminal` to `--leader terminal`. Pass remaining flags through.
- **`history`** → Show history: `python3 scripts/bench-agent.py --history`
- **`compare`** → Compare runs: `python3 scripts/bench-agent.py --compare` followed by the remaining args.

If `$ARGUMENTS` is empty, show this usage guide:

```
tm-bench — Agent Team Communication Benchmark

Usage:
  /tm-bench agent                   Interactive mode selector
  /tm-bench agent --pane            Pane infrastructure, terminal leader
  /tm-bench agent --headless        Headless infrastructure
  /tm-bench agent --llm             LLM leader (Claude --claude-leader)
  /tm-bench agent --rpc             RPC infrastructure only
  /tm-bench agent --e2e             E2E agent tests only
  /tm-bench agent --note "..."      Add a change note to the run
  /tm-bench history                 Show recent benchmark history
  /tm-bench compare A B             Compare two runs by timestamp prefix

Results saved to: ~/.term-mesh/benchmarks/YYYY-MM-DDTHH-MM-SS.json
```

## Subcommand Reference

| Command | Description |
|---------|-------------|
| `agent` | Interactive menu: select leader type + infra mode + layers |
| `agent --pane` | Pane infrastructure only |
| `agent --headless` | Headless infrastructure only |
| `agent --llm` | LLM leader E2E (creates team with --claude-leader) |
| `agent --terminal` | Terminal leader E2E (script-driven, uses existing team) |
| `agent --rpc` | RPC latency benchmarks only |
| `agent --e2e` | E2E agent communication only |
| `agent --note "msg"` | Attach a change description to the benchmark run |
| `history` | Show last 10 benchmark results in a table |
| `compare A B` | Side-by-side comparison of two runs by timestamp prefix |

## Leader Types

| | Terminal Leader | LLM Leader |
|---|---|---|
| **Who** | Script / user types `tm-agent delegate` | Claude agent orchestrates autonomously |
| **Routing** | Fixed assignment | Context-aware, by agent specialty |
| **Verification** | Status field check | Semantic response interpretation |
| **Error handling** | Timeout → FAIL | Re-delegate, reassign, retry |
| **Overhead** | ~0ms | LLM call latency (~2-10s) |

## Execution

1. Parse `$ARGUMENTS` and run the appropriate `python3 scripts/bench-agent.py` command via Bash
2. If no flags → show interactive menu for configuration
3. Show the output to the user
4. Results are automatically saved to `~/.term-mesh/benchmarks/YYYY-MM-DDTHH-MM-SS.json`
5. If a previous run exists, a comparison delta is printed automatically
