# /watch — Stateless Drift Oversight

## Goal

Fresh watcher가 **spec + watched agent의 최근 delta**만 보고 execution/direction drift를 판정한다. watcher는 기억하는 동료가 아니라 매번 새 눈으로 보는 stateless 검수자다.

## Responsibility

| Command | Responsibility |
|---------|----------------|
| `/tm` | one-shot fan-out dispatch. 모든 idle agent에게 작업을 보내고 결과를 synthesis한다. |
| `/tm-op pair` | one-shot pair 라운드. 한 번만 반박/보조 관점을 붙인다. |
| `/watch` | oversight 전용 review/on/off/status 토글. drift를 검출하고 leader에게 보고한다. |

`/watch`는 fan-out dispatch를 수행하지 않는다. `/watch review`와 `/watch on`은 팀과 watcher가 없을 때 최초 1회 자동 생성한다(one-time bootstrap). 기존 에이전트를 제거하거나 watcher CLI/model을 임의로 변경하지 않는다. `/watch off`, `/watch status`, `/watch test`는 팀 구성을 절대 변경하지 않는다. `/watch test`는 첫 틱을 기다리지 않고 한 번의 drift check를 즉시 강제 실행해 watch 파이프라인이 실제로 동작하는지 검증하는 self-test다(`watch on`이 켜져 있어야 함). 팀 구성은 그대로 두지만 watch 카운터(`check_count`/`last_check_ts`)는 갱신되므로 순수 read-only인 `status`와 구분된다.

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
- `test` -> [Subcommand: test]
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
  /watch test   [agent]          force one check now; report verdict

Responsibility:
  /tm           fan-out dispatch
  /tm-op pair   one-shot pair round
  /watch        oversight review/on/off/status/test only
```

For every other invocation (empty input, unrecognized token, or a subcommand missing required inputs), run the **full interactive wizard**. Only `/watch help` prints documentation; everything else acts.

**Wizard steps** — use `AskUserQuestion`, one step at a time. Skip any step already satisfied by command-line args:

1. **Action**: if no subcommand was given, ask which action — `review`, `on`, `off`, `status`, `test`.
2. **Target agent**: ask which agent — list each worker (except leader and watcher) plus an "all workers" option. For `off`/`status`, "all" is allowed.
3. **Spec** (review/on only): ask what to watch; accept inline text or an `@path`. Required, no default.
4. **Stance** (review/on only): ask the lens — `critic` (default), `advisor`, `pair`.
5. **Watcher CLI** (review/on only): ask which CLI runs the watcher — `claude` (default), `codex`, `gemini`, `kiro`. This sets both the watcher pane CLI (`tm-agent attach watcher --cli <cli>`) and the autonomous headless tick CLI (`tm-agent watch on --cli <cli>`). The watcher needs no skill install on any CLI — each tick is a headless one-shot whose spec is folded into the system prompt. Pre-select the current team default when one exists, else `claude`.
6. **Interval** (on only): ask the autonomous interval in seconds (default `300`).
7. **Confirm & run**: when the wizard collected one or more values, show the resolved command and run it. If all required inputs were already supplied on the command line, run directly with NO confirmation step.

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

In the interactive wizard, prompt for every input the chosen action needs that was not supplied on the command line — including `--stance` (default `critic`), `--cli` (default `claude`, the watcher CLI), and, for `on`, `--every` (default `300`) — pre-selecting the defaults. Always respect values already passed on the command line and skip prompting for those. If all required inputs are already supplied, run directly without any prompt. Under `--no-input`, never prompt: require flags and reject when a required input is missing.

`off` and `status` do not require a spec.

### Spec resolution

- `--spec @path`: read the file at execution time. For `on`, store the path so future cycles live-read it.
- `--spec <text>`: use the provided text verbatim.
- team spec: use the watcher/team custom instructions when already configured.

Never expand the spec into persistent watcher context. Every check gets a fresh prompt containing only the resolved spec and bounded recent delta.

### Task-format override

The watch spec is the default oversight contract, not a higher-priority output schema. If the leader's current task capsule gives a more specific output format, severity taxonomy, review lens, file scope, or verify command, that task instruction wins for that task. Do not count the format difference itself as drift. Example: if a reviewer spec says `P0-P3 + VERDICT` but the active review task explicitly requires security-lens findings as `[SEVERITY]`, the watcher must treat `[SEVERITY]` as an allowed task-format override and only flag real scope, safety, or correctness drift.

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

0. Ensure team + watcher exist (auto-create on first use):

   ```bash
   tm-agent status
   ```

   Interpret the result:
   - Normal JSON with `team_name` and `agents` = team exists. Verify watcher **liveness** (below) before step 1.
   - Error JSON (`{"ok":false,...}`) or non-zero exit = no active team.

   **No active team:**
   - **Interactive:** prompt "활성 team이 없습니다. 새 team을 생성하고 watch를 시작할까요?" (Yes/No).
     - Yes → bootstrap from the current pane in ONE step (adopts this pane as leader AND creates the watcher in the current workspace):
       ```bash
       tm-agent attach watcher --cli <cli>
       ```
     - No → exit cleanly.
   - **Non-interactive (`--no-input`):** proceed silently without prompting, using the same single-step bootstrap:
     ```bash
     tm-agent attach watcher --cli <cli>
     ```

   > **Why `attach`, not `create --adopt` + `add`:** `tm-agent create 1 --adopt` can fail to adopt the caller's pane and instead spawn the team in a *separate* workspace. A subsequent `tm-agent add watcher` then resolves the caller's own workspace id (`ws-<first8hex>`), finds no team there, and fails with `team_not_found`. `tm-agent attach watcher` is workspace-local: it adopts the calling pane as leader and auto-creates team `ws-<first8hex>` from the current workspace UUID, so the watcher always lands in the user's pane. Use `attach` for first-use bootstrap.

   **Team exists, but no watcher agent (absent from the agent list):**
   - If the existing team is `create`-based (status `team_name` is not `ws-…`), add via the team-scoped route:
     ```bash
     tm-agent add watcher --cli <cli>
     ```
   - If the team is the workspace-local `ws-…` team (or `add` returns `team_not_found`), use the workspace-local route instead:
     ```bash
     tm-agent attach watcher --cli <cli>
     ```

   **Team + watcher both listed — confirm liveness and auto-repair phantoms with one call:**
   Registry presence ≠ a live pane: a watcher can be listed in `tm-agent status` yet never have spawned, and enabling watch on such a phantom makes every tick fail with `recycle failed: workspace_missing`. `tm-agent watch doctor` probes liveness (`team.read` not_found **or** `tm-agent status` showing `panel_id`/`workspace_id` missing), guards the fresh-spawn race (5 s grace poll), and repairs a confirmed phantom **once** through the team's own creation path — then re-verifies and fails loud rather than looping. Pass the `team_name` from `tm-agent status`:

   ```bash
   tm-agent watch doctor <team>        # [watcher] defaults to `watcher`; team-type-aware repair; one-shot; fails loud
   ```

   > **`heartbeat_age_seconds: null` is a weak signal, never a phantom trigger on its own** — healthy idle panes report null until their first heartbeat. doctor treats only `read` not_found / missing `panel_id`·`workspace_id` as proof; it never repairs on null alone.

   Interpret the exit code:

   | exit | meaning |
   |------|---------|
   | `0` | healthy, or phantom repaired and now live |
   | `2` | phantom confirmed but `--no-repair` set (diagnose only) |
   | `3` | repair attempted once but watcher still not live — fail loud, do NOT retry |
   | `4` | H7 routing risk (GUI team but app socket unresolved → tick may misroute headless) |
   | `1` | usage / RPC / socket-resolution error |

   On non-zero, surface the JSON `error` field; do not hand-roll the detach/attach dance — doctor performs the team-type-correct repair (create-based → `remove`+`add`, `ws-…` → `detach`+`attach`).

1. Resolve target workers:

   - If `[agent]` is provided, verify that agent exists and is not the watcher.
   - If `[agent]` is omitted: in **interactive** mode, prompt with `AskUserQuestion` to choose the target — list each worker agent (except leader and watcher) as an option plus an "all workers" option (default). In **non-interactive** mode, target all worker agents except leader and watcher.

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

Enable daemon autonomous watch for one target, all workers, or the **leader's own pane**. This is no longer a stub: it uses `tm-agent watch on`, persists config in `.xm/watch/config.json`, and starts the daemon interval trigger.

**Target values:** `<agent>` (one worker) · `all` (every worker except leader/watcher) · `leader` (the leader's own pane). `leader` is for worker-less teams (e.g. an `attach`-bootstrapped 1-person team) where the real work happens in the leader pane. Two ways in:

- **Explicit:** `--target leader`.
- **Fallback (D1, conservative):** with `--target all`, when the team resolves to **zero workers** and exposes a GUI leader pane, the daemon automatically watches `leader`. As soon as one real worker exists, `all` watches workers only — the leader is never watched in a multi-member team. A purely headless leader (no GUI pane) has nothing to capture, so no fallback applies and watch reports "no target".

When the target is `leader`, the watcher tolerates in-progress/streaming output (it is the user's live work, not a worker's settled result) and drift reports are tagged `[self-watch]` in the leader inbox.

### Flow

0. Ensure team + watcher exist (auto-create on first use) — same logic as `review` Step 0. Run `tm-agent status`; if no team exists, bootstrap from the current pane with `tm-agent attach watcher --cli <cli>` (single step: adopts this pane as leader AND creates the watcher — see the "Why `attach`" note in `review` Step 0). If a team exists but has no watcher, add one with `tm-agent add watcher --cli <cli>` (or `attach` for `ws-…` workspace-local teams). The chosen `--cli` must match the watcher CLI selected in the wizard so the pane and the autonomous tick CLI agree. **Also apply `review` Step 0's watcher liveness check** by running `tm-agent watch doctor <team>` (team_name from `tm-agent status`): it probes, guards the fresh-spawn race, and repairs a confirmed phantom once (team-type aware), then fails loud. Proceed to enable watch only on exit `0`; on `2`/`3`/`4` surface the JSON `error` and stop. Skipping this lets every tick fail with `recycle failed: workspace_missing`.

1. Resolve and validate the spec exactly as `review` does, including the interactive spec prompt when it is missing (reject only in non-interactive mode).
2. Resolve `[agent]` to a single target, `all` workers, or `leader`. Do not create or remove panes. If `[agent]` is omitted: in **interactive** mode, prompt with `AskUserQuestion` to choose the target (same choices as `review`, plus `leader` when the team has no workers); in **non-interactive** mode, default to all workers (which auto-falls-back to `leader` when zero workers resolve and a GUI leader pane exists). If `--stance` or `--every` were omitted: in interactive mode prompt for them (defaults `critic` / `300`); under `--no-input` apply the defaults silently.
3. Execute the daemon watch primitive:

   ```bash
   tm-agent watch on --target <agent|all|leader> --every <sec> --stance <stance> --cli <cli> --model <model> --spec <text|@path> --ratio <R>
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

First check for an active team. If no team exists, print and exit:

```text
WATCH: already off (no active team)
```

Otherwise:

```bash
tm-agent watch off <agent|all>
```

The daemon sets `enabled=false`, stops timers, and preserves `.xm/watch/config.json` for audit or later re-enable. Do not close agents. Do not modify team composition.

## Subcommand: status

`/watch status [agent]`

Show daemon watch configuration, scheduler state, and recent drift history.

### Flow

First check for an active team with `tm-agent status`. If no team exists, print and exit:

```text
WATCH: n/a (no active team — run /watch on or /team-up to create one)
```

Otherwise:

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

## Subcommand: test

`/watch test [agent]`

Force one drift check immediately, bypassing the cadence timer, then report the verdict. This is the self-test for "does the watch pipeline actually fire?" — it removes the need to wait a full `--every` interval (e.g. 300 s) after `/watch on` just to confirm the watcher spawns, returns a verdict, and the board records it.

`test` requires `watch on` to already be enabled for the team. It does not create a team, add a watcher, change CLI/model, or alter team composition. It is **not** read-only: the daemon increments `check_count` and `last_check_ts` for the forced tick. The optional `[agent]` is informational only — `watch.trigger_now` fires for the whole team's configured target (single agent, all workers, or leader), not a per-agent override.

### Flow

First check for an active team with `tm-agent status`. If no team exists, print and exit:

```text
WATCH: n/a (no active team — run /watch on or /team-up to create one)
```

1. Resolve the team name from `tm-agent status` (the `team_name` field).
2. Force one check:

   ```bash
   tm-agent watch trigger <team_name>
   ```

   - `TRIGGERED: false` → the daemon rejected the fire. Report the `REASON` verbatim and stop. Common reasons:
     - `watch is not enabled for this team` → run `/watch on` first.
     - `a check is already in progress for this team` → a tick is in flight; wait and retry.
     - `no workers configured` → set a target via `/watch on [agent] --spec ...`.
   - `TRIGGERED: true` → continue. Note the returned `CHECK_COUNT`.

3. The daemon fires the check in the background, so poll `watch status` until the forced tick settles (it clears `in_flight`/`running` and writes `last_error`). Use a short bounded wait — re-run every ~2 s up to ~`reply_timeout` (default 120 s):

   ```bash
   tm-agent watch status <team_name>
   ```

   Stop polling when `running`/`in_flight` is `false` **and** `check_count` has advanced to the value returned by `trigger`.

4. Read the freshest verdict for this tick from `.xm/watch/board.jsonl` (last appended row, or the row whose `check_id` matches this tick). A drift finding is one JSON row; no new row means the watcher returned an OK verdict (no drift).

5. Print a compact self-test result:

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

Interpretation for the leader:
- `LAST_ERROR: n/a` + `SETTLED: true` → the watch pipeline works end to end (spawn → verdict → settle). The autonomous interval can be trusted.
- `LAST_ERROR: <message>` → the pipeline fired but the watcher run failed (CLI path, spec resolve, timeout). Fix before relying on autonomous ticks.
- `SETTLED: false` → the check did not finish within the poll window; report it and suggest re-running `/watch status` shortly.

`/watch test` does not send watcher findings anywhere itself; the daemon `WatchController` owns leader-inbox reporting and the board append for the forced tick exactly as it does for scheduled ticks. `/watch test` only reads and summarizes.

## Anti-patterns

1. **Do not depend on `~/.term-mesh/results/<team>/` for drift history.** Result files are pruned after 24h. Use `.xm/watch/board.jsonl`.
2. **Do not send watcher findings directly to watched agents.** Use `tm-agent msg send "<finding>"` to leader only; never `--to <agent>`.
3. **Do not accumulate watcher context.** Every review must hard-restart or use a true one-shot watcher. Input is only spec + recent delta.
4. **Do not use native team tools.** No `TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, or `TeamDelete`.
5. **Do not fan out from `/watch`.** `/watch` audits; `/tm` dispatches.
6. **Auto-create on first use, never destroy.** `/watch review` and `/watch on` may create the team and add a watcher when missing (one-time bootstrap). Never remove existing agents, never reassign watcher CLI/model behind the user's back. **Exception — phantom repair (one-shot, hard-proof only):** `tm-agent watch doctor <team>` performs this exception. A watcher counts as a no-live-pane phantom only when `read` is **still** `not_found` after a ≤5 s grace poll, or `tm-agent status` shows it with `panel_id`/`workspace_id` missing — `heartbeat_age_seconds: null` alone is NOT proof (healthy idle panes report null too). doctor then repairs once, branched to mirror creation (`remove`+`add` for a create-based team, `detach`+`attach` for a `ws-…` team, same name/CLI), and fails loud if still not live — it never loops. `/watch off`, `/watch status`, and `/watch test` never mutate team composition (`test` forces a tick and advances watch counters, but adds/removes no panes).
7. **Do not edit code from watcher.** watcher proposes course corrections; leader decides and assigns implementation.
8. **Do not let watcher write side effects.** watcher returns a structured verdict only. Manual `/watch review` writes through the leader command; autonomous `/watch on` writes through daemon `WatchController`.
9. **Do not auto-apply course corrections.** `/watch` is report-only in both manual and autonomous modes.
10. **Do not let autonomous ticks steal focus or overlap indefinitely.** daemon ticks run in the background, obey `--every`/budget guards, and skip overruns while a check is `in_flight`.

## Examples

### Recommended spec template

Use a spec that states the stable contract, but explicitly leaves room for task-specific output formats:

```text
# Watch Spec
Goal: <what the watcher must protect>
Default lens: <critic|advisor|pair expectations>
Default output: <baseline verdict shape, e.g. VERDICT/DRIFT_TYPE/SEVERITY/FINDING/SPEC_CLAUSE>
Task override: if the leader's current task capsule specifies a more specific output format, severity taxonomy, review lens, file scope, or verify command, obey the task capsule for that task. Do not record drift for format differences alone.
Count as drift: <ignored errors, false success, scope escape, forbidden side effects, unsafe behavior>
Do not count as drift: <task-format override, explicitly read-only behavior, intentionally narrower scope>
Reporting: leader-only structured verdict. The watcher never edits code, messages watched agents, or writes `.xm/watch/board.jsonl`.
```

Reviewer spec example:

```text
Goal: keep code review focused on regressions that matter.
Default lens: prioritize P0-P3 bugs, behavioral regressions, missing tests, and incorrect verification.
Default output: findings first with file:line and VERDICT.
Task override: task-specific review lenses and output schemas are allowed. If the leader asks for security findings as [SEVERITY] or another taxonomy, treat that format as compliant and judge only the substance.
Count as drift: reviewing unrelated files, inventing findings, ignoring failed tests, or reporting success without evidence.
Do not count as drift: using a task-requested severity schema instead of P0-P3.
```

Executor spec example:

```text
Goal: keep implementation scoped and verified.
Default lens: confirm changed files match the task, tests/builds are run or blockers are explicit, and no unrelated refactor lands.
Default output: changed files, verify command, result, next action.
Task override: if the task capsule names exact files, verification commands, or a different report header, prefer that task contract for this run.
Count as drift: editing outside scope, skipping required verify, hiding failures, or committing when forbidden.
Do not count as drift: stopping at read-only analysis when the task says read-only.
```

Security spec example:

```text
Goal: catch security regressions introduced or worsened by the target diff.
Default lens: command injection, path traversal, socket/auth boundary, secret exposure, unsafe process/env handling.
Default output: severity, file:line, evidence snippet, fix.
Task override: if the task capsule defines a severity format such as [SEVERITY] or limits findings to Medium+, use that task-specific taxonomy and threshold.
Count as drift: reporting pre-existing Low issues as blocking, missing a new exploitable path, or exposing secrets in the report.
Do not count as drift: omitting Low findings when the task asks for Medium+ only.
```

### Spec resolution

Three forms are accepted for `--spec`:

| Form | Meaning |
|------|---------|
| `"literal text"` | Spec text used verbatim every tick. |
| `@path/to/spec.md` | File read live from disk each tick (relative to working dir). |
| `preset:<name>` | Shorthand for `@.xm/watch/specs/<name>.md`. |

**Built-in presets** (files in `.xm/watch/specs/`):

| Name | Focus |
|------|-------|
| `executor` | Implementation scope, verify compliance, no unrelated refactor |
| `reviewer` | P0-P3 bugs, behavioral regressions, missing tests |
| `security` | Command injection, path traversal, secret exposure, auth boundary |
| `general` | General execution + direction drift across all workers |

Usage:

```bash
tm-agent watch on standard --target executor --spec preset:executor
tm-agent watch on standard --target all --spec preset:general
```

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

### First-time bootstrap (no team, no watcher)

```bash
/watch review executor --spec @docs/feature.md --stance critic
```

Expected internal shape (sequential tm-agent calls):

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
rg -n "watch on|watch off|watch status|watch trigger|watch test|trigger_now|WatchController|next_tick|--every|daemon|autonomous" .claude/commands/watch.md
```
