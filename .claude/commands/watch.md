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

**CRITICAL:** Do NOT use Claude Code native team tools (`TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, `TeamDelete`). All operations route through `tm-agent`.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse the first token of `$ARGUMENTS` and route to the matching subcommand:

- `review` -> [Subcommand: review] 실행
- `on` -> [Subcommand: on] 실행
- `off` -> [Subcommand: off] 실행
- `status` -> [Subcommand: status] 실행
- empty input -> help 출력 후 종료
- unrecognized token -> valid subcommand 목록 출력 후 종료

### Empty input

If `$ARGUMENTS` is empty, print:

```text
/watch — stateless drift oversight

Usage:
  /watch review [agent] --spec <text|@path> [--stance critic|advisor|pair]
  /watch on [agent] --spec <text|@path> [--every 300]
  /watch off
  /watch status

Responsibility:
  /tm          fan-out dispatch
  /tm-op pair one-shot pair round
  /watch      oversight review/on/off/status only
```

Then stop. Do not run `tm-agent status` for empty input unless the user explicitly asks for status.

## Options

Parse common options before executing any subcommand.

| Option | Default | Applies to | Description |
|--------|---------|------------|-------------|
| `--stance critic|advisor|pair` | `critic` | review/on | watcher lens |
| `--cli claude|codex|gemini` | current team default | review/on | watcher CLI preference |
| `--model <m>` | CLI default | review/on | watcher model preference |
| `--spec <text|@path>` | team spec if present | review/on | required spec source |
| `--every <sec>` | `300` | on only | Phase 2 interval setting |

`review` and `on` require a spec. If no team spec exists and `--spec` is missing, reject with:

```text
REJECT: /watch review/on requires a spec. Provide --spec "<text>" or --spec @path.
```

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
   - If `[agent]` is omitted, target all worker agents except leader and watcher.
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
   - Remind watcher: no code edits, no `tm-agent msg send`, no `.xm/watch/board.jsonl` writes. watcher returns only the structured verdict; this `/watch` leader command owns reporting and persistence.

5. Wait and read watcher result:

   ```bash
   tm-agent wait --timeout 120 --mode any
   tm-agent read <watcher> --lines 120
   ```

6. Report drift to leader inbox only. This `/watch` leader command is the only owner of `tm-agent msg send` for watcher findings:

   ```bash
   tm-agent msg send "<finding>"
   ```

   Never use `tm-agent msg send --to <agent>` for watcher feedback. The leader owns approval and course correction.

7. Append drift findings to `.xm/watch/board.jsonl` exactly once. This `/watch` leader command is the only board writer in Phase 1:

   ```json
   {"check_id":"<sha256(ts + agent + spec_clause) or uuid>","ts":"<iso8601>","agent":"<watched-agent>","drift_type":"execution|direction","severity":"<severity>","finding":"<finding>","spec_clause":"<spec clause>"}
   ```

   Create `.xm/watch/` if needed. Append only one JSON object per line. Use `check_id` as an idempotency key: before appending, skip the write if the same `check_id` already exists. If no drift is found, do not append a finding; the watcher should return a structured OK verdict.

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

Enable watch configuration for a future interval runner. Phase 1 does not start an autonomous interval loop.

### Phase 1 behavior

1. Validate spec exactly as `review` does.
2. Resolve `[agent]` to a single target or all workers.
3. Persist or print the intended config:

   ```json
   {"enabled":true,"agent":"<agent|all>","stance":"critic|advisor|pair","cli":"<cli>","model":"<model>","spec":"<text|@path>","every_seconds":300}
   ```

4. Print:

   ```text
   Watch config recorded. Autonomous interval execution is Phase 2; run `/watch review ...` for an immediate check.
   ```

Do not dispatch work. Do not create team members. Do not start a background loop unless the daemon has a dedicated watch interval primitive.

### Phase 2 target behavior

When a daemon interval primitive exists, `on` may store config and let `term-meshd` run stateless one-shot checks every `--every <sec>`. Each cycle must still use fresh context and bounded delta.

## Subcommand: off

`/watch off`

Disable the persisted watch configuration.

Phase 1 behavior:

```text
Watch disabled. Remove or mark disabled the current .xm/watch config if present.
```

Do not close agents. Do not modify team composition.

## Subcommand: status

`/watch status`

Show current watch configuration and summarize recent drift history.

### Flow

1. Read current config if present.
2. Read `.xm/watch/board.jsonl` if present.
3. Print:

```text
WATCH: on|off
TARGET: <agent|all|n/a>
STANCE: critic|advisor|pair|n/a
SPEC: <text|@path|team|n/a>
DRIFT_COUNT_THIS_SESSION: <unique check_id count, or line count for legacy rows without check_id>
RECENT:
  <check_id> <ts> <agent> <drift_type> <severity> <finding>
```

If `.xm/watch/board.jsonl` is missing, print `DRIFT_COUNT_THIS_SESSION: 0`. If duplicate `check_id` rows exist, count them once and show the newest row for each key.

## Anti-patterns

1. **Do not depend on `~/.term-mesh/results/<team>/` for drift history.** Result files are pruned after 24h. Use `.xm/watch/board.jsonl`.
2. **Do not send watcher findings directly to watched agents.** Use `tm-agent msg send "<finding>"` to leader only; never `--to <agent>`.
3. **Do not accumulate watcher context.** Every review must hard-restart or use a true one-shot watcher. Input is only spec + recent delta.
4. **Do not use native team tools.** No `TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, or `TeamDelete`.
5. **Do not fan out from `/watch`.** `/watch` audits; `/tm` dispatches.
6. **Do not mutate team composition.** Missing watcher is a reject with setup guidance, not an implicit add.
7. **Do not edit code from watcher.** watcher proposes course corrections; leader decides and assigns implementation.
8. **Do not let watcher write side effects in Phase 1.** watcher returns a structured verdict only; `/watch` leader command is the sole owner of `tm-agent msg send` and `.xm/watch/board.jsonl` append.

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

### Enable planned interval config

```bash
/watch on reviewer --spec @docs/release-checklist.md --every 300 --cli codex --model opus
```

Phase 1 records or prints the config and reminds the user that autonomous interval execution is Phase 2.

### Check drift history

```bash
/watch status
```

Reads `.xm/watch/board.jsonl` and summarizes this session's drift count.

## Verify

After editing this command file:

```bash
test -f .claude/commands/watch.md && rg -n "review|on|off|status|--stance|--spec|board.jsonl|msg send" .claude/commands/watch.md
```
