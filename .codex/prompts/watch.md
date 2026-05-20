---
description: "term-mesh watch — stateless drift review and oversight toggle"
---

# /watch — Codex Watch Shim

User provided: $ARGUMENTS

Use this prompt as the Codex leader wrapper for `/watch`. All operations must use `tm-agent`; do not use Codex sub-agents, native delegation, or any disconnected team state for term-mesh team work.

`.claude/commands/watch.md` is the single source of truth. This file is a compressed IME shim for Codex leaders and must not contradict the Claude command.

## Empty input

If `$ARGUMENTS` is empty, print:

```text
/watch — stateless drift oversight

  /watch review [agent] --spec <text|@path> [--stance critic|advisor|pair]
  /watch on [agent] --spec <text|@path> [--every 300]
  /watch off
  /watch status

Responsibilities:
  /tm          fan-out dispatch
  /tm-op pair one-shot pair round
  /watch      oversight review/on/off/status only
```

Then stop.

## Parse arguments

Parse the first token of `$ARGUMENTS`:

- `review` — on-demand stateless drift check
- `on` — store or display watch config; autonomous interval is Phase 2
- `off` — disable watch config
- `status` — show config and summarize `.xm/watch/board.jsonl`

Common flags:

- `--stance critic|advisor|pair` — default `critic`
- `--cli claude|codex|gemini`
- `--model <m>`
- `--spec <text|@path>`
- `--every <sec>` — `on` only, default `300`

`review` and `on` require a spec from team config or `--spec`. If no spec exists, reject:

```text
REJECT: /watch review/on requires a spec. Provide --spec "<text>" or --spec @path.
```

## Workflow

### `review [agent]`

1. Resolve team, watcher, and target workers:
   ```bash
   tm-agent status
   ```
   If watcher is missing, tell the user to run `/team add watcher` or `tm-agent add watcher`. Do not auto-add it.

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

7. Send drift finding to leader only. The Codex `/watch` leader shim is the only owner of watcher finding messages:
   ```bash
   tm-agent msg send "<finding>"
   ```

8. Append each drift finding to `.xm/watch/board.jsonl` exactly once. The Codex `/watch` leader shim is the only Phase 1 board writer:
   ```json
   {"check_id":"<sha256(ts + agent + spec_clause) or uuid>","ts":"<iso8601>","agent":"<watched-agent>","drift_type":"execution|direction","severity":"<severity>","finding":"<finding>","spec_clause":"<spec clause>"}
   ```
   Use `check_id` as an idempotency key: before appending, skip the write if the same `check_id` already exists. If watcher returns OK, do not append a drift finding.

### `on [agent]`

Validate spec and resolve target like `review`, then store or print config:

```json
{"enabled":true,"agent":"<agent|all>","stance":"critic|advisor|pair","cli":"<cli>","model":"<model>","spec":"<text|@path>","every_seconds":300}
```

Print that autonomous interval execution is Phase 2 and suggest `/watch review ...` for an immediate check. Do not dispatch work, add agents, or start a background loop unless a daemon watch primitive exists.

### `off`

Disable the watch config. Do not close agents and do not mutate team composition.

### `status`

Read current config if present and summarize `.xm/watch/board.jsonl`:

```text
WATCH: on|off
TARGET: <agent|all|n/a>
STANCE: critic|advisor|pair|n/a
SPEC: <text|@path|team|n/a>
DRIFT_COUNT_THIS_SESSION: <unique check_id count, or line count for legacy rows without check_id>
RECENT:
  <check_id> <ts> <agent> <drift_type> <severity> <finding>
```

If the board is missing, report drift count `0`. If duplicate `check_id` rows exist, count them once and show the newest row for each key.

## Guardrails

- Use `tm-agent` only. Do not use Codex sub-agents for term-mesh team work.
- `/watch` never fan-outs user work and never changes team composition.
- Never send watcher findings with `tm-agent msg send --to <agent>`; send to the leader only with `tm-agent msg send "<finding>"`.
- Do not store drift history only under `~/.term-mesh/results`; those files are pruned. Use `.xm/watch/board.jsonl`.
- Keep watcher context fresh every check: hard restart or true one-shot, with input limited to spec + recent delta.
- watcher returns a structured verdict only; this leader shim is the sole owner of `tm-agent msg send` and `.xm/watch/board.jsonl` append in Phase 1.
- watcher proposes course corrections only; code edits are leader-approved follow-up work.
