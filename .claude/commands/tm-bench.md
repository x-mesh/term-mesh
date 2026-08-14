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
| `agent` | **Interactive selector** (use `AskUserQuestion`, see below) |
| (empty) | **Interactive selector** (same as `agent`) |
| `agent N` | **Interactive selector** with `--repeat N` (e.g. `agent 5` → run 5 iterations) |
| `agent --pane` | `python3 scripts/bench-agent.py --mode pane` |
| `agent --headless` | `python3 scripts/bench-agent.py --mode headless` |
| `agent --llm` | `python3 scripts/bench-agent.py --leader llm` |
| `agent --terminal` | `python3 scripts/bench-agent.py --leader terminal --mode pane` |
| `agent --rpc` | `python3 scripts/bench-agent.py --rpc-only --mode pane --leader terminal` |
| `agent --e2e` | `python3 scripts/bench-agent.py --e2e-only --mode pane --leader terminal` |
| `effectiveness [flags]` | `python3 scripts/bench-agent-effectiveness.py run [flags]` |
| `effectiveness-validate [flags]` | `python3 scripts/bench-agent-effectiveness.py validate-suite [flags]` |
| `effectiveness-report RUN` | `python3 scripts/bench-agent-effectiveness.py report RUN` |
| `agent --note "..."` | append `--note "..."` to the command |
| `history` | `python3 scripts/bench-agent.py --history` |
| `compare A B` | `python3 scripts/bench-agent.py --compare A B` |

Map the first word of `$ARGUMENTS`:

- **`agent` (no flags)** or **empty** → Interactive selector (see Interactive Flow below)
- **`agent N`** (bare number, e.g. `agent 5`) → Interactive selector with `--repeat N` appended to the final command. Parse the number and pass through the Interactive Flow, then append `--repeat N` when executing.
- **`agent` (with flags)** → Map `--pane` to `--mode pane`, `--headless` to `--mode headless`, `--llm` to `--leader llm`, `--terminal` to `--leader terminal`. If a bare number is present among flags, extract it as `--repeat N`. Pass remaining flags through.
- **`history`** → Show history: `python3 scripts/bench-agent.py --history`
- **`compare`** → Compare runs: `python3 scripts/bench-agent.py --compare` followed by the remaining args.
- **`effectiveness`** → Run the paired 18-run single-session vs three-worker decision benchmark.
- **`effectiveness-validate`** → Prove baseline failure, oracle success, and history isolation.
- **`effectiveness-report`** → Regenerate metrics; pass `--evaluate` for blinded quality judges.

## Argument Parsing Precedence

When parsing `$ARGUMENTS` for the `agent` subcommand, apply these rules in order:

1. **Explicit `--repeat N` has highest priority.** If `$ARGUMENTS` contains `--repeat N`, use that value and do not search for bare numbers.
2. **Extract the first bare integer as `--repeat N`.** If no explicit `--repeat` is present, scan tokens left-to-right and extract the first standalone integer (a token that is a number and not an argument value) as `--repeat N`.
3. **Preserve remaining flags.** All non-extracted tokens (`--pane`, `--llm`, `--headless`, `--terminal`, `--rpc`, `--e2e`, `--note`, etc.) are passed through unchanged.

### Parsing Examples

| Input | `--repeat` | Mapped flags | Result |
|-------|-----------|-------------|--------|
| `agent` | (none) | (none) | Interactive selector |
| `agent 5` | `--repeat 5` | (none) | Interactive, 5 iterations |
| `agent --llm` | (none) | `--leader llm` | Interactive, LLM leader |
| `agent 5 --llm` | `--repeat 5` | `--leader llm` | Interactive, 5 iter, LLM leader |
| `agent --llm 3` | `--repeat 3` | `--leader llm` | Interactive, 3 iter, LLM leader |
| `agent --repeat 5 --pane --llm` | `--repeat 5` (explicit) | `--mode pane --leader llm` | Interactive, 5 iter, pane, LLM leader |

## Interactive Flow (for bare `agent` or empty arguments)

When `$ARGUMENTS` is empty or just `agent` with no flags:

1. **Detect current state** — Run `tm-agent status` to check for an active team (name, agent count).

2. **Ask with `AskUserQuestion`** — Present a single-select question based on detected state:

   **Question:** "Which benchmark to run?"
   **Header:** "Benchmark"

   Build options dynamically:

   | Option label | Description | When to show | Maps to |
   |---|---|---|---|
   | **Existing team E2E (Recommended)** | `{team_name} ({N} agents), no new team — fastest` | Team detected | `--e2e-only --mode pane --leader terminal` |
   | **Existing team E2E** | `No active team detected — will fail without one` | No team | `--e2e-only --mode pane --leader terminal` |
   | **Full pane benchmark** | `RPC (temp team) + E2E (existing team)` | Always | `--mode pane --leader terminal` |
   | **RPC only** | `Infrastructure latency only (creates temp team)` | Always | `--rpc-only --mode pane --leader terminal` |
   | **LLM leader E2E** | `Creates new team with --claude-leader` | Always | `--leader llm` |

   When team is detected: show 4 options (Existing team E2E recommended, Full pane, RPC only, LLM leader).
   When no team: show 3 options (Full pane recommended, RPC only, LLM leader). Skip "Existing team E2E".

3. **Ask for a change note** — After benchmark selection, ask with a second `AskUserQuestion`:

   **Question:** "Change note? (e.g. 렌더링 ON, headless 모드, after refactor)"
   **Header:** "Note"

   Options (single-select):
   | Option label | Description |
   |---|---|
   | **Skip** | `No note — just run the benchmark` |
   | **렌더링 ON** | `Terminal rendering enabled` |
   | **렌더링 OFF** | `Terminal rendering disabled` |
   | **Custom** | `Enter a custom note` |

   - If user selects "Skip" → no `--note` flag
   - If user selects a preset → append `--note "렌더링 ON"` (or OFF) to the command
   - If user selects "Other" (custom text) → append `--note "{user_input}"` to the command

4. **Run the mapped command** — Take the user's selection, map to the flags above, and execute:
   ```
   python3 scripts/bench-agent.py {mapped flags} [--note "..."]
   ```

5. **Show output** to the user.

## Subcommand Reference

| Command | Description |
|---------|-------------|
| `agent` | Interactive menu: select leader type + infra mode + layers |
| `agent N` | Interactive menu + run N iterations (e.g. `agent 5`) |
| `agent --pane` | Pane infrastructure only |
| `agent --headless` | Headless infrastructure only |
| `agent --llm` | LLM leader E2E (creates team with --claude-leader) |
| `agent --terminal` | Terminal leader E2E (script-driven, uses existing team) |
| `agent --rpc` | RPC latency benchmarks only |
| `agent --e2e` | E2E agent communication only |
| `agent --note "msg"` | Attach a change description to the benchmark run |
| `effectiveness --dry-run` | Validate fixture metadata and print the paired 18-run matrix |
| `effectiveness-validate` | Validate baseline/oracle behavior and history isolation |
| `effectiveness-report RUN --evaluate` | Generate blinded quality comparison and final report |
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

For `effectiveness`, use isolated teams and repositories owned by the runner. Never reuse or
destroy the user's current team. A full run makes 18 paid leader calls plus corrections and worker
calls; run `effectiveness --dry-run` first unless the user explicitly requested execution. The
protocol and adoption gates are in `docs/multi-agent-effectiveness-benchmark.md`.

1. Parse `$ARGUMENTS` and run the mapped Python command via Bash
2. If no flags → show interactive menu for configuration
3. Show the output to the user
4. Agent transport results go to `~/.term-mesh/benchmarks/`; effectiveness artifacts go to
   `~/.term-mesh/benchmarks/effectiveness/<run-id>/`.
5. If a previous run exists, a comparison delta is printed automatically
