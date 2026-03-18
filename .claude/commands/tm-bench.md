# tm-bench — Agent Team Communication Benchmark

Run automated benchmarks on the term-mesh agent team communication system.
Measures RPC infrastructure latency and end-to-end agent response times.
Results are saved as JSON and compared with previous runs to track improvements.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse `$ARGUMENTS` to determine the subcommand:

| Input | Command |
|-------|---------|
| `agent` | `python3 scripts/bench-agent.py` |
| `agent --rpc` | `python3 scripts/bench-agent.py --rpc-only` |
| `agent --e2e` | `python3 scripts/bench-agent.py --e2e-only` |
| `agent --note "..."` | `python3 scripts/bench-agent.py --note "..."` |
| `history` | `python3 scripts/bench-agent.py --history` |
| `compare A B` | `python3 scripts/bench-agent.py --compare A B` |

Map the first word of `$ARGUMENTS`:

- **`agent`** → Run benchmarks. Pass any remaining flags (`--rpc`, `--e2e`, `--note "..."`) through to the script.
- **`history`** → Show history: `python3 scripts/bench-agent.py --history`
- **`compare`** → Compare runs: `python3 scripts/bench-agent.py --compare` followed by the remaining args.

If `$ARGUMENTS` is empty, show this usage guide:

```
tm-bench — Agent Team Communication Benchmark

Usage:
  /tm-bench agent              Run all benchmarks (RPC + E2E)
  /tm-bench agent --rpc        RPC infrastructure only (no team needed)
  /tm-bench agent --e2e        E2E agent tests only (needs active team)
  /tm-bench agent --note "..." Add a change note to the run
  /tm-bench history            Show recent benchmark history
  /tm-bench compare A B        Compare two runs by timestamp prefix

Results saved to: ~/.term-mesh/benchmarks/YYYY-MM-DDTHH-MM-SS.json
```

## Subcommand Reference

| Command | Description |
|---------|-------------|
| `agent` | Run all benchmarks (RPC infrastructure + E2E agent tests) |
| `agent --rpc` | RPC only — creates/destroys a temporary `bench-rpc` team |
| `agent --e2e` | E2E only — requires an active team (`/team create N --claude-leader`) |
| `agent --note "msg"` | Attach a change description to the benchmark run |
| `history` | Show last 10 benchmark results in a table |
| `compare A B` | Side-by-side comparison of two runs by timestamp prefix |

## Execution

1. Parse `$ARGUMENTS` and run the appropriate `python3 scripts/bench-agent.py` command via Bash
2. Show the output to the user
3. Results are automatically saved to `~/.term-mesh/benchmarks/YYYY-MM-DDTHH-MM-SS.json`
4. If a previous run exists, a comparison delta is printed automatically
