# /watch — Stateless Drift Oversight

## Goal

Fresh watcher가 **spec + watched agent의 최근 delta**만 보고 execution/direction drift를 판정한다. watcher는 기억하는 동료가 아니라 매번 새 눈으로 보는 stateless 검수자다.

## Responsibility

| Command | Responsibility |
|---------|----------------|
| `/tm` | one-shot fan-out dispatch. 모든 idle agent에게 작업을 보내고 결과를 synthesis한다. |
| `/tm-op pair` | one-shot pair 라운드. 한 번만 반박/보조 관점을 붙인다. |
| `/watch` | oversight 전용 review/on/off/status 토글. drift를 검출하고 leader에게 보고한다. |

`/watch`는 fan-out dispatch를 수행하지 않는다. 팀 구성도 변경하지 않는다. watcher가 없으면 자동 생성하지 말고 `/team add watcher` 또는 `tm-agent add watcher` 실행을 안내한다.

Writer ownership:

- Manual `/watch review`: the leader command owns `tm-agent msg send` and `.xm/watch/board.jsonl` append.
- Autonomous `/watch on`: daemon `WatchController` owns `tm-agent msg send` and `.xm/watch/board.jsonl` append.
- watcher returns only a structured verdict in both modes; it never writes side effects.

**CRITICAL:** Do NOT use Claude Code native team tools (`TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, `TeamDelete`). All operations route through `tm-agent`.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse the first token and route:

- `help` -> print the usage block (see below) and stop. This is the ONLY case that prints documentation.
- `review` -> [Subcommand: review]
- `on` -> [Subcommand: on]
- `off` -> [Subcommand: off]
- `status` -> [Subcommand: status]
- empty input -> start the full interactive wizard
- unrecognized token -> start the full interactive wizard

A recognized subcommand still enters the wizard for any required input it is missing, unless `--no-input` is set. Only `/watch help` prints documentation; every other invocation acts.

### Interactive wizard (default)

If the first token is `help`, print this usage block and stop:

```text
/watch — stateless drift oversight

Usage:
  /watch help                    show this help
  /watch review [agent] --spec <text|@path> [--stance critic|advisor|pair]
  /watch on     [agent] --spec <text|@path> [--every 300]
  /watch off    [agent|all]
  /watch status [agent]

Responsibility:
  /tm           fan-out dispatch
  /tm-op pair   one-shot pair round
  /watch        oversight review/on/off/status only
```

For every other invocation (empty input, unrecognized token, or a subcommand missing required inputs), run the **full interactive wizard**. Only `/watch help` prints documentation; everything else acts.

**Wizard steps** — use `AskUserQuestion`, one step at a time. Skip any step already satisfied by command-line args:

1. **Action**: if no subcommand was given, ask which action — `review`, `on`, `off`, `status`.
2. **Target agent**: ask which agent — list each worker (except leader and watcher) plus an "all workers" option. For `off`/`status`, "all" is allowed.
3. **Spec** (review/on only): ask what to watch; accept inline text or an `@path`. Required, no default.
4. **Stance** (review/on only): ask the lens — `critic` (default), `advisor`, `pair`.
5. **Interval** (on only): ask the autonomous interval in seconds (default `300`).
6. **Confirm & run**: when the wizard collected one or more values, show the resolved command and run it. If all required inputs were already supplied on the command line, run directly with NO confirmation step.

Non-interactive context (`--no-input` / automation / headless): do NOT run the wizard. Require all inputs as flags; reject when a required input is missing (see each subcommand).

## Options

Parse common options before executing any subcommand.

| Option | Default | Applies to | Description |
|--------|---------|------------|-------------|
| `--stance critic|advisor|pair` | `critic` | review/on | watcher lens |
| `--cli claude|codex|gemini` | current team default | review/on | watcher CLI preference |
| `--model <m>` | CLI default | review/on | watcher model preference |
| `--spec <text|@path>` | team spec if present | review/on | required spec source |
| `--every <sec>` | `300` | on only | daemon autonomous interval |
| `--ratio <R>` | daemon default | on only | autonomous budget or sampling ratio |

`review` and `on` require a spec. Resolve in order: `--spec` flag, then team spec.

If no spec can be resolved:
- **Interactive (default):** do NOT reject. Prompt the user for the spec with `AskUserQuestion` (or a single direct question if the tool is unavailable): ask what to watch and accept either inline spec text or an `@path`. Use the answer as the spec for this run only; never persist it.
- **Non-interactive (`--no-input` / automation / headless):** reject with:

```text
REJECT: /watch review/on requires a spec. Provide --spec "<text>" or --spec @path.
```

In the interactive wizard, prompt for every input the chosen action needs that was not supplied on the command line — including `--stance` (default `critic`) and, for `on`, `--every` (default `300`) — pre-selecting the defaults. Always respect values already passed on the command line and skip prompting for those. If all required inputs are already supplied, run directly without any prompt. Under `--no-input`, never prompt: require flags and reject when a required input is missing.

`off` and `status` do not require a spec.

### Spec resolution

- `--spec @path`: read the file at execution time. For `on`, store the path so future cycles live-read it.
- `--spec <text>`: use the provided text verbatim.
- team spec: use the watcher/team custom instructions when already configured.

Never expand the spec into persistent watcher context. Every check gets a fresh prompt containing only the resolved spec and bounded recent delta.

### Stance lens

| Stance | Behavior |
|--------|----------|
| `critic` | 회의적 검수. spec 위반, skipped errors, wrong files, false success, scope drift를 우선 찾는다. |
| `advisor` | 건설적 제안. spec 충족 여부를 판단하고 low-risk course correction을 제안한다. |
| `pair` | ADR-W2: one watcher, not two panes. Return one report with `[CRITIC]`, `[ADVISOR]`, `[VERDICT]` blocks. |

## Subcommand: review

`/watch review [agent] [options]`

On-demand stateless check. If `[agent]` is omitted, review all worker agents except leader and watcher. This command does not dispatch the user's task to workers; it only audits their recent output.

### Flow

1. Check team state and resolve targets:

   ```bash
   tm-agent status
   ```

   - If no team exists, reject and ask the user to create/adopt a team first.
   - If `[agent]` is provided, verify that agent exists and is not the watcher.
   - If `[agent]` is omitted: in **interactive** mode, prompt with `AskUserQuestion` to choose the target — list each worker agent (except leader and watcher) as an option plus an "all workers" option (default). In **non-interactive** mode, target all worker agents except leader and watcher.
   - Verify a watcher agent exists. If missing, stop with:

   ```text
   REJECT: watcher agent not found. Run `/team add watcher` or `tm-agent add watcher`, then retry.
   ```

2. Collect recent bounded delta:

   ```bash
   tm-agent collect --lines N
   # or for one target:
   tm-agent read <agent> --lines N
   ```

   Use the smallest `N` that preserves recent task state. Do not read full transcript history.

3. Hard-restart the watcher pane to obtain fresh context:

   ```bash
   tm-agent restart <watcher> --hard
   ```

   If the local `tm-agent` does not yet expose `restart`, stop and say the MVP requires a hard restart primitive before stateless review can be trusted. Do not fake freshness by reusing accumulated watcher context.

4. Send exactly one stateless review prompt to watcher:

   ```bash
   tm-agent send <watcher> '<spec + bounded delta + stance lens>'
   ```

   Prompt requirements:
   - Include `SPEC` verbatim.
   - Include only `RECENT DELTA`, never full history.
   - Include `WATCHED AGENT: <agent|all workers>`.
   - Ask for `execution` vs `direction` drift classification.
   - Ask for severity, finding, spec_clause, and suggested course correction.
   - For `pair`, require `[CRITIC]`, `[ADVISOR]`, `[VERDICT]` blocks.
   - Remind watcher: no code edits, no `tm-agent msg send`, no `.xm/watch/board.jsonl` writes. watcher returns only the structured verdict; this manual `/watch review` leader command owns reporting and persistence.

5. Wait and read watcher result:

   ```bash
   tm-agent wait --timeout 120 --mode any
   tm-agent read <watcher> --lines 120
   ```

6. Report drift to leader inbox only. For manual `/watch review`, this leader command is the owner of `tm-agent msg send` for watcher findings:

   ```bash
   tm-agent msg send "<finding>"
   ```

   Never use `tm-agent msg send --to <agent>` for watcher feedback. The leader owns approval and course correction.

7. Append drift findings to `.xm/watch/board.jsonl` exactly once. This manual `/watch review` leader command is the board writer for on-demand checks:

   ```json
   {"check_id":"<sha256(ts + agent + spec_clause) or uuid>","ts":"<iso8601>","agent":"<watched-agent>","drift_type":"execution|direction","severity":"<severity>","finding":"<finding>","spec_clause":"<spec clause>"}
   ```

   Create `.xm/watch/` if needed. Append only one JSON object per line. Use `check_id` as an idempotency key: before appending, skip the write if the same `check_id` already exists. If no drift is found, do not append a finding; the watcher should return a structured OK verdict. Autonomous checks use the same verdict schema, `check_id`, and board format, but daemon `WatchController` is the single writer for those ticks.

### Review result shape

Watcher result should be compact and must not perform side effects:

```text
VERDICT: DRIFT|OK
AGENT: <agent>
DRIFT_TYPE: execution|direction|n/a
SEVERITY: blocker|high|medium|low|info
FINDING: <one sentence>
SPEC_CLAUSE: <quoted or summarized clause>
COURSE_CORRECTION: <leader-owned next action>
```

For `--stance pair`:

```text
[CRITIC]
...
[ADVISOR]
...
[VERDICT]
VERDICT: DRIFT|OK
...
```

## Subcommand: on

`/watch on [agent] --spec <text|@path> [--every <sec>] [options]`

Enable daemon autonomous watch for one target or all workers. This is no longer a stub: it uses `tm-agent watch on`, persists config in `.xm/watch/config.json`, and starts the daemon interval trigger.

### Flow

1. Resolve and validate the spec exactly as `review` does, including the interactive spec prompt when it is missing (reject only in non-interactive mode).
2. Resolve `[agent]` to a single target or `all` workers. Do not create or remove panes. If `[agent]` is omitted: in **interactive** mode, prompt with `AskUserQuestion` to choose the target (same choices as `review`); in **non-interactive** mode, default to all workers. If `--stance` or `--every` were omitted: in interactive mode prompt for them (defaults `critic` / `300`); under `--no-input` apply the defaults silently.
3. Execute the daemon watch primitive:

   ```bash
   tm-agent watch on --target <agent|all> --every <sec> --stance <stance> --cli <cli> --model <model> --spec <text|@path> --ratio <R>
   ```

   Omit optional flags that the user did not provide; let daemon defaults apply.

4. Report the daemon response, including persisted config and `next_tick`.

Autonomous writer ownership:

- daemon `WatchController` is the single owner of leader inbox reporting and `.xm/watch/board.jsonl` append for interval ticks.
- watcher still returns only a structured verdict; it never calls `tm-agent msg send` and never writes the board.
- Manual `/watch review` and autonomous `/watch on` share the same verdict schema, `check_id`, and board row shape.

Runtime constraints:

- Report-only: never auto-apply fixes or send correction messages to watched agents.
- Focus-safe: daemon background ticks must not steal user focus or select panes.
- Cost guards: enforce daemon minimum `--every`, budget/ratio limits, and skip ticks when a previous check is still `in_flight`.
- Stateless: each tick uses a fresh headless one-shot watcher prompt with only spec + bounded recent delta.

## Subcommand: off

`/watch off [agent|all]`

Disable daemon autonomous watch.

### Flow

```bash
tm-agent watch off <agent|all>
```

The daemon sets `enabled=false`, stops timers, and preserves `.xm/watch/config.json` for audit or later re-enable. Do not close agents. Do not modify team composition.

## Subcommand: status

`/watch status [agent]`

Show daemon watch configuration, scheduler state, and recent drift history.

### Flow

1. Query daemon watch state:

   ```bash
   tm-agent watch status
   # or for one target:
   tm-agent watch status --target <agent>
   ```

2. Summarize `.xm/watch/board.jsonl` if the daemon response does not already include recent findings.
3. Print:

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

If `.xm/watch/board.jsonl` is missing, print `DRIFT_COUNT_THIS_SESSION: 0`. If duplicate `check_id` rows exist, count them once and show the newest row for each key. `status` is read-only and must not start or stop timers.

## Anti-patterns

1. **Do not depend on `~/.term-mesh/results/<team>/` for drift history.** Result files are pruned after 24h. Use `.xm/watch/board.jsonl`.
2. **Do not send watcher findings directly to watched agents.** Use `tm-agent msg send "<finding>"` to leader only; never `--to <agent>`.
3. **Do not accumulate watcher context.** Every review must hard-restart or use a true one-shot watcher. Input is only spec + recent delta.
4. **Do not use native team tools.** No `TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, or `TeamDelete`.
5. **Do not fan out from `/watch`.** `/watch` audits; `/tm` dispatches.
6. **Do not mutate team composition.** Missing watcher is a reject with setup guidance, not an implicit add.
7. **Do not edit code from watcher.** watcher proposes course corrections; leader decides and assigns implementation.
8. **Do not let watcher write side effects.** watcher returns a structured verdict only. Manual `/watch review` writes through the leader command; autonomous `/watch on` writes through daemon `WatchController`.
9. **Do not auto-apply course corrections.** `/watch` is report-only in both manual and autonomous modes.
10. **Do not let autonomous ticks steal focus or overlap indefinitely.** daemon ticks run in the background, obey `--every`/budget guards, and skip overruns while a check is `in_flight`.

## Examples

### On-demand review of one agent

```bash
/watch review executor --spec @docs/feature-spec.md --stance critic
```

Expected internal shape:

```bash
tm-agent status
tm-agent read executor --lines 120
tm-agent restart watcher --hard
tm-agent send watcher '<SPEC + RECENT DELTA + critic lens>'
tm-agent wait --timeout 120 --mode any
tm-agent read watcher --lines 120
tm-agent msg send '<finding>'
```

### Pair stance without two panes

```bash
/watch review executor --spec "Implement only the documented socket command" --stance pair
```

Watcher returns one report:

```text
[CRITIC]
...
[ADVISOR]
...
[VERDICT]
WATCH: DRIFT
DRIFT_TYPE: execution
...
```

### Enable autonomous interval watch

```bash
/watch on reviewer --spec @docs/release-checklist.md --every 300 --cli codex --model opus
```

Expected internal shape:

```bash
tm-agent watch on --target reviewer --spec @docs/release-checklist.md --every 300 --stance critic --cli codex --model opus
```

The daemon persists `.xm/watch/config.json`, starts interval checks, and returns `next_tick`.

### Disable autonomous watch

```bash
/watch off reviewer
```

Expected internal shape:

```bash
tm-agent watch off reviewer
```

### Check drift history

```bash
/watch status
```

Reads `.xm/watch/board.jsonl` and summarizes this session's drift count.

## Verify

After editing this command file:

```bash
rg -n "watch on|watch off|watch status|WatchController|next_tick|--every|daemon|autonomous" .claude/commands/watch.md .codex/prompts/watch.md
```
