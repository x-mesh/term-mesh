---
description: "term-mesh watch — stateless drift review and oversight toggle"
---

# /watch — Codex Watch Shim

User provided: $ARGUMENTS

Use this prompt as the Codex leader wrapper for `/watch`. All operations must use `tm-agent`; do not use Codex sub-agents, native delegation, or any disconnected team state for term-mesh team work.

`.claude/commands/watch.md` is the single source of truth. This file is a compressed IME shim for Codex leaders and must not contradict the Claude command.

## Routing and interactive wizard

If the first token is `help`, print this usage block and stop — this is the ONLY case that prints documentation:

```text
/watch — stateless drift oversight

Usage:
  /watch help                    show this help
  /watch review [agent] --spec <text|@path|preset:<name>> [--stance critic|advisor|pair]
  /watch on     [agent] --spec <text|@path|preset:<name>> [--every 300]
  /watch off    [agent|all]
  /watch status [agent]
  /watch test   [agent]          force one check now; report verdict

Responsibility:
  /tm           fan-out dispatch
  /tm-op pair   one-shot pair round
  /watch        oversight review/on/off/status/test only
```

For every other invocation (empty input, unrecognized token, or a recognized subcommand missing required inputs), run the **full interactive wizard**. Only `/watch help` prints documentation; everything else acts.

**Wizard steps** — ask the user directly and wait for their reply, one step at a time. Skip any step already satisfied by command-line args:

1. **Action**: if no subcommand was given, ask which action — `review`, `on`, `off`, `status`, `test`.
2. **Target agent**: ask which agent — list each worker (except leader and watcher) plus an "all workers" option. For `off`/`status`, "all" is allowed.
3. **Spec** (review/on only): ask what to watch; accept inline text or an `@path`. Required, no default.
4. **Stance** (review/on only): ask the lens — `critic` (default), `advisor`, `pair`.
5. **Watcher CLI** (review/on only): ask which CLI runs the watcher — `claude` (default), `codex`, `gemini`, `kiro`. Sets both the watcher pane CLI (`tm-agent attach watcher --cli <cli>`) and the autonomous headless tick CLI (`tm-agent watch on --cli <cli>`). No skill install is needed on any CLI — each tick is a headless one-shot whose spec is folded into the system prompt. Pre-select the current team default, else `claude`.
6. **Interval** (on only): ask the autonomous interval in seconds (default `300`).
7. **Confirm & run**: when the wizard collected one or more values, show the resolved command and run it. If all required inputs were already supplied on the command line, run directly with NO confirmation step.

Non-interactive context (`--no-input` / automation / headless): do NOT run the wizard. Require all inputs as flags; reject when a required input is missing.

## Parse arguments

Parse the first token of `$ARGUMENTS`:

- `help` — print the usage block (see above) and stop. This is the ONLY case that prints documentation.
- `review` — on-demand stateless drift check
- `on` — enable daemon autonomous watch via `tm-agent watch on`
- `off` — disable daemon autonomous watch via `tm-agent watch off`
- `status` — show daemon watch config and summarize `.xm/watch/board.jsonl`
- `test` — force one check now via `tm-agent watch trigger`, then report the verdict
- empty input or unrecognized token — start the full interactive wizard

A recognized subcommand still enters the wizard for any required input it is missing, unless `--no-input` is set.

Common flags:

- `--stance critic|advisor|pair` — default `critic`
- `--cli claude|codex|gemini`
- `--model <m>`
- `--spec <text|@path|preset:<name>>` — built-in presets: `executor`, `reviewer`, `security`, `general`
- `--every <sec>` — `on` only, default `300`
- `--ratio <R>` — `on` only, daemon budget or sampling ratio

`review` and `on` require a spec. Resolve in order: `--spec` flag, then team spec.
`preset:<name>` expands to `.xm/watch/specs/<name>.md` under the working directory.

Task-format override: the spec is the default oversight contract. If the leader's current task capsule gives a more specific output format, severity taxonomy, review lens, file scope, or verify command, that task instruction wins for that task. Do not report drift for format differences alone. Full template examples live in `.claude/commands/watch.md`; the compressed form is: `Goal`, `Default lens`, `Default output`, `Task override`, `Count as drift`, `Do not count as drift`, `Reporting`.

If no spec can be resolved:
- **Interactive (default):** do NOT reject. Ask the user a direct question and wait for their reply: ask what to watch and accept either inline spec text or an `@path`. Use the answer as the spec for this run only; never persist it.
- **Non-interactive (`--no-input` / automation / headless):** reject with:

```text
REJECT: /watch review/on requires a spec. Provide --spec "<text>", --spec @path, or --spec preset:<name>.
```

In the interactive wizard, ask the user directly and wait for their reply for every input the chosen action needs that was not supplied on the command line — including `--stance` (default `critic`), `--cli` (default `claude`, the watcher CLI), and, for `on`, `--every` (default `300`) — pre-selecting the defaults. Always respect values already passed on the command line and skip asking for those. If all required inputs are already supplied, run directly without any prompt. Under `--no-input`, never prompt: require flags and reject when a required input is missing.

## Workflow

### `review [agent]`

0. Ensure team + watcher exist (auto-create on first use):
   ```bash
   tm-agent status
   ```
   - Normal JSON with `team_name` and `agents` = team exists. Verify watcher **liveness** (below) before step 1.
   - Error JSON (`{"ok":false,...}`) or non-zero exit = no active team.

   **No active team:**
   - **Interactive:** ask "활성 team이 없습니다. 새 team을 생성하고 watch를 시작할까요?" (Yes/No). Yes → `tm-agent attach watcher --cli <cli>` (single step: adopts THIS pane as leader AND creates the watcher in the current workspace). No → exit.
   - **Non-interactive (`--no-input`):** proceed silently → `tm-agent attach watcher --cli <cli>`.

   > **Why `attach`, not `create --adopt` + `add`:** `tm-agent create 1 --adopt` can fail to adopt the caller's pane and spawn the team in a *separate* workspace; a later `tm-agent add watcher` then resolves the caller's own `ws-<first8hex>`, finds no team, and fails with `team_not_found`. `attach` is workspace-local — it adopts the calling pane and auto-creates `ws-<first8hex>`, so the watcher always lands in the user's pane.

   **Team exists, no watcher:** `tm-agent add watcher --cli <cli>` for `create`-based teams, or `tm-agent attach watcher --cli <cli>` for `ws-…` workspace-local teams (or if `add` returns `team_not_found`).

   **Watcher listed but a phantom (liveness) — one call confirms and repairs:** registry presence ≠ a live pane (a watcher can be listed yet never have spawned; enabling watch on it makes every tick fail with `recycle failed: workspace_missing`). Run `tm-agent watch doctor <team>` (team_name from `tm-agent status`; `[watcher]` defaults to `watcher`): it probes liveness (`read` not_found **or** status `panel_id`/`workspace_id` missing), guards the fresh-spawn race (5 s grace poll), and repairs a confirmed phantom **once** through the team's own creation path (create-based → `remove`+`add`, `ws-…` → `detach`+`attach`), then re-verifies and fails loud — never loops. **`heartbeat_age_seconds: null` is a weak signal, never a trigger alone** — healthy idle panes report null until their first heartbeat; doctor never repairs on null. Interpret exit: `0` healthy/repaired-live · `2` phantom + `--no-repair` · `3` repair failed (do NOT retry) · `4` H7 routing risk · `1` RPC/socket error. On non-zero, surface the JSON `error`.

1. Resolve target workers:
   If `[agent]` is provided, verify it exists and is not the watcher.
   If `[agent]` is omitted: in **interactive** mode, ask the user a direct question and wait for their reply — list each worker agent (except leader and watcher) as a choice plus an "all workers" option (default). In **non-interactive** mode, target all worker agents except leader and watcher.

2. Resolve spec. For `--spec @path`, read the file now. For text spec, use it verbatim.

3. Collect bounded recent delta only:
   ```bash
   tm-agent collect --lines N
   tm-agent read <agent> --lines N
   ```
   Never include full history.

4. Freshen watcher context:
   ```bash
   tm-agent restart <watcher> --hard
   ```
   If restart is unavailable, stop and report that stateless review needs a hard restart or one-shot primitive.

5. Send one stateless prompt:
   ```bash
   tm-agent send <watcher> '<SPEC + RECENT DELTA + stance lens>'
   ```
   Include `SPEC`, `RECENT DELTA`, `WATCHED AGENT`, stance, execution-vs-direction drift classification, severity, finding, spec_clause, and course correction request. For `pair`, request one report with `[CRITIC]`, `[ADVISOR]`, `[VERDICT]`. Tell watcher to return only a structured verdict and not to run `tm-agent msg send` or write `.xm/watch/board.jsonl`.

6. Wait and read:
   ```bash
   tm-agent wait --timeout 120 --mode any
   tm-agent read <watcher> --lines 120
   ```

7. Send drift finding to leader only. For manual `/watch review`, the Codex `/watch` leader shim is the owner of watcher finding messages:
   ```bash
   tm-agent msg send "<finding>"
   ```

8. Append each drift finding to `.xm/watch/board.jsonl` exactly once. For manual `/watch review`, the Codex `/watch` leader shim is the board writer:
   ```json
   {"check_id":"<sha256(ts + agent + spec_clause) or uuid>","ts":"<iso8601>","agent":"<watched-agent>","drift_type":"execution|direction","severity":"<severity>","finding":"<finding>","spec_clause":"<spec clause>"}
   ```
   Use `check_id` as an idempotency key: before appending, skip the write if the same `check_id` already exists. If watcher returns OK, do not append a drift finding. Autonomous `/watch on` uses the same structured verdict schema, `check_id`, and board row shape, but daemon `WatchController` is the single writer for interval ticks.

### `on [agent]`

0. Ensure team + watcher exist (auto-create on first use) — same logic as `review` Step 0. Run `tm-agent status`; if no team exists, bootstrap from the current pane with `tm-agent attach watcher --cli <cli>` (single step: adopts this pane as leader AND creates the watcher — see the "Why `attach`" note in `review` Step 0). If a team exists but has no watcher, add with `tm-agent add watcher --cli <cli>` (or `attach` for `ws-…` workspace-local teams). The chosen `--cli` must match the watcher CLI selected in the wizard so the pane and the autonomous tick CLI agree. **Also apply the `review` Step 0 liveness check** by running `tm-agent watch doctor <team>` (team_name from `tm-agent status`): it probes, guards the fresh-spawn race, and repairs a confirmed phantom once (team-type aware), then fails loud. Enable watch only on exit `0`; on `2`/`3`/`4` surface the JSON `error` and stop. Otherwise every tick fails with `recycle failed: workspace_missing`.

Resolve and validate the spec exactly as `review` does, including the interactive spec prompt when it is missing (reject only in non-interactive mode). Resolve `[agent]` the same way as `review`: in **interactive** mode, ask the user a direct question and wait for their reply; in **non-interactive** mode, default to all workers. Targets: `<agent>` (one worker) · `all` (every worker except leader/watcher) · `leader` (the leader's own pane, for worker-less teams). With `--target all`, a team that resolves to **zero workers** but exposes a GUI leader pane auto-falls-back to watching `leader` (D1 conservative: once any worker exists, `all` watches workers only; a purely headless leader gets no fallback and reports "no target"). A `leader` target tolerates in-progress output and tags drift reports `[self-watch]`. Then enable daemon autonomous watch:

```bash
tm-agent watch on --target <agent|all|leader> --every <sec> --stance <stance> --cli <cli> --model <model> --spec <text|@path> --ratio <R>
```

Omit optional flags the user did not provide. The daemon persists `.xm/watch/config.json`, starts interval ticks, and returns `next_tick` plus current config. This command does not dispatch user work, add agents, close panes, or mutate team composition.

Autonomous ownership and UX:

- daemon `WatchController` is the single writer for leader inbox messages and `.xm/watch/board.jsonl` during interval ticks.
- watcher returns only structured verdict fields: `VERDICT`, `drift_type`, `severity`, `finding`, `spec_clause`.
- The mode is report-only; it never auto-applies fixes and never sends feedback with `--to <agent>`.
- daemon ticks run in the background without stealing focus.
- Cost guards must be respected: daemon minimum `--every`, budget/ratio limits, and `in_flight` overrun skip.
- Each tick uses fresh headless one-shot watcher context with only spec + bounded recent delta.

### `off [agent|all]`

First check for an active team with `tm-agent status`. If no team exists, print and exit:

```text
WATCH: already off (no active team)
```

Otherwise, disable daemon autonomous watch:

```bash
tm-agent watch off <agent|all>
```

The daemon sets `enabled=false`, stops timers, and preserves `.xm/watch/config.json`. Do not close agents and do not mutate team composition.

### `status [agent]`

First check for an active team with `tm-agent status`. If no team exists, print and exit:

```text
WATCH: n/a (no active team — run /watch on or /team-up to create one)
```

Otherwise, query daemon watch status and summarize `.xm/watch/board.jsonl`:

```bash
tm-agent watch status
tm-agent watch status --target <agent>
```

```text
WATCH: on|off
TARGET: <agent|all|n/a>
STANCE: critic|advisor|pair|n/a
SPEC: <text|@path|team|n/a>
NEXT_TICK: <iso8601|n/a>
LAST_TICK: <iso8601|n/a>
BUDGET: <remaining/limit|n/a>
LAST_ERROR: <message|n/a>
DRIFT_COUNT_THIS_SESSION: <unique check_id count, or line count for legacy rows without check_id>
RECENT:
  <check_id> <ts> <agent> <drift_type> <severity> <finding>
```

If the board is missing, report drift count `0`. If duplicate `check_id` rows exist, count them once and show the newest row for each key.

### `test [agent]`

Self-test: force one check now instead of waiting a full `--every` interval, then report the verdict. Requires `watch on` to be enabled. Does not create a team, add a watcher, or change composition; it does advance `check_count`/`last_check_ts`, so it is not read-only. The optional `[agent]` is informational — `trigger` fires for the team's configured target, not a per-agent override.

First check for an active team with `tm-agent status`. If no team exists, print `WATCH: n/a (no active team — run /watch on or /team-up to create one)` and exit. Otherwise resolve `team_name` from `tm-agent status` and:

```bash
tm-agent watch trigger <team_name>
```

- `TRIGGERED: false` → report `REASON` verbatim and stop (`watch is not enabled` → run `/watch on` first; `a check is already in progress` → wait and retry; `no workers configured` → set a target via `/watch on`).
- `TRIGGERED: true` → the daemon fires in the background. Poll `tm-agent watch status <team_name>` every ~2 s (bounded by `reply_timeout`, default 120 s) until `running`/`in_flight` is `false` and `check_count` reaches the value `trigger` returned, then read the freshest row from `.xm/watch/board.jsonl` (no new row = OK verdict, no drift).

```text
WATCH TEST: <team_name>
TRIGGERED: true
CHECK_COUNT: <n>
SETTLED: true|false (timeout)
LAST_ERROR: <message|n/a>
VERDICT: OK|DRIFT|unknown
RECENT:
  <check_id> <ts> <agent> <drift_type> <severity> <finding>   # only when DRIFT
```

`LAST_ERROR: n/a` + `SETTLED: true` means the pipeline works end to end and the autonomous interval can be trusted. A `LAST_ERROR` means the tick fired but the watcher run failed (CLI path, spec resolve, timeout) — fix before relying on autonomous ticks. `SETTLED: false` means the check did not finish within the poll window. `/watch test` only reads and summarizes; the daemon `WatchController` still owns leader-inbox reporting and the board append for the forced tick.

## Guardrails

- Use `tm-agent` only. Do not use Codex sub-agents for term-mesh team work.
- `/watch review` and `/watch on` auto-create team + watcher on first use (one-time bootstrap). Never remove existing agents, never reassign watcher CLI/model behind the user's back. **Exception — phantom repair (one-shot, hard-proof only):** `tm-agent watch doctor <team>` performs this exception. A watcher counts as a no-live-pane phantom only when `read` is **still** `not_found` after a ≤5 s grace poll, or `tm-agent status` shows `panel_id`/`workspace_id` missing — `heartbeat_age_seconds: null` alone is NOT proof (healthy idle panes report null too). doctor then repairs once, branched to mirror creation (`remove`+`add` for a create-based team, `detach`+`attach` for a `ws-…` team, same name/CLI), and fails loud if still not live — it never loops. `/watch off`, `/watch status`, and `/watch test` never mutate team composition (`test` forces a tick and advances watch counters, but adds/removes no panes).
- Never send watcher findings with `tm-agent msg send --to <agent>`; send to the leader only with `tm-agent msg send "<finding>"`.
- Do not store drift history only under `~/.term-mesh/results`; those files are pruned. Use `.xm/watch/board.jsonl`.
- Keep watcher context fresh every check: hard restart or true one-shot, with input limited to spec + recent delta.
- watcher returns a structured verdict only. Manual `/watch review` writes through this leader shim; autonomous `/watch on` writes through daemon `WatchController`.
- Do not treat task-format override as drift: when the active task explicitly requests a different output schema or severity taxonomy, judge substance against the spec and task together.
- watcher proposes course corrections only; code edits are leader-approved follow-up work.
- Autonomous watch is report-only, focus-safe, cost-guarded, and skips overlapping checks while a prior tick is `in_flight`.

## Example: First-time bootstrap (no team, no watcher)

```bash
/watch review executor --spec @docs/feature.md --stance critic
```

Expected internal shape:

```bash
tm-agent status                        # → error/no team
# interactive: "활성 team이 없습니다. 새 team을 생성하고 watch를 시작할까요?" → Yes
# wizard also asks: watcher CLI (claude|codex|gemini|kiro), default claude
tm-agent attach watcher --cli claude   # one-step bootstrap: adopts THIS pane as leader + creates watcher
tm-agent status                        # confirm watcher registered
tm-agent read executor --lines 120
tm-agent restart watcher --hard
tm-agent send watcher '<SPEC + RECENT DELTA + critic lens>'
tm-agent wait --timeout 120 --mode any
tm-agent read watcher --lines 120
tm-agent msg send '<finding>'
```
