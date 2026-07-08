# x-kit (xm) Panel Integration — Phase 2, term-mesh side

Status: **T1 done** (daemon `xk_run` kind + opt-in filter + caps, unit-tested) ·
**T2 done** (xk-bridge mirrors run lifecycle onto the task board via `team.task.*`
app-socket RPCs — `handle_xk_run` in `daemon/term-mesh-cli/src/tm_agent.rs`; Phase-1
branch merged into this phase2 branch to provide the bridge) · **T3 done** (this doc +
CLAUDE.md note) · **T4 authored** (`tests_v2/test_daemon_xk_run_events.py` — run on the
UTM VM; SKIPs cleanly when no daemon socket exists).

Original plan below. The integration contract source of truth lives in the xm
repo: `xm/docs/x-panel-term-mesh-phase2.md` (event schema `XK-EVENTS-v1`, requirements,
cross-repo task table). This doc covers only what changes **in this repo**.

Phase 2 themes: real-time visibility of x-panel runs inside term-mesh, and agent/leader
efficiency (task-board mirroring instead of leader-side polling).

Phase 1 recap: branch `claude/xkit-term-mesh-integration-rie8ws` (**unmerged**) added
`tm-agent xk-bridge` (daemon `reply`/`task_status` events → `.xm/` tasks/trace/metrics
writeback) and the contract-pointer docs. Task T2 below depends on that branch merging;
T1/T3/T4 do not.

---

## T1 — daemon: `xk_run` event kind

`daemon/term-meshd/src/socket.rs` currently accepts only `task_status` | `reply` in
`events.publish` and defaults `events.subscribe` filters to
`task_status/reply/heartbeat_stale/agent_usage_tick`.

Changes:

1. New `DaemonEvent::XkRun` variant carrying the `XK-EVENTS-v1` payload fields
   (`v, source, run, run_kind, phase, model, state, elapsed_ms, tail, title, ts_ms`) —
   passthrough fan-out only, **no persistence** (files under `.xm/` remain the durable record).
2. `events.publish` accepts `kind:"xk_run"`; validation: `source` and `run` non-empty,
   whole event ≤ 4 KiB, `tail` truncated server-side to 512 bytes.
3. `events.subscribe` delivers `xk_run` **only** when explicitly requested via
   `kinds:["xk_run", …]`. The default filter set is unchanged, so existing subscribers
   (`tm-agent wait`, Swift) see zero new traffic.
4. Threading: pure bus fan-out on the daemon side — no main-actor work, consistent with the
   socket command threading policy (telemetry hot path, off-main, coalesced by the publisher).

done_criteria: `cargo test` covering publish→subscribe round-trip of an `xk_run` event;
a default-filter subscriber receives none; an oversized event is rejected with a clear error.

## T2 — tm-agent: xk-bridge mirrors panel runs onto the task board

Depends on: Phase-1 branch merge (owns `run_xk_bridge`) + T1.
**Gate: ask the user before starting — the Phase-1 merge is their call.**

Extend the xk-bridge subscribe loop to also request `xk_run` and map run lifecycle onto the
team task board, so a leader can `tm-agent wait` on a panel instead of polling files
(leader-efficiency: no `sleep && cat status.json` loops, no context spent on poll output):

| xk_run event | task board action |
|---|---|
| first event for a `run` (`phase:"starting"`) | `task create "panel:<run_kind> <title>"` (idempotent per run id) |
| phase transitions | task status `in_progress`; per-model `state` summarized into the task's progress note |
| `phase:"done"` | task `completed` |
| `phase:"failed"` | task `blocked` with the failing models in the reason |

Rules: idempotent on duplicate/out-of-order events (keyed by `run`); unknown `v` ignored at
debug level; never creates tasks for runs already terminal.

done_criteria: with a live team, a stubbed `xk_run` sequence produces exactly one board task
transitioning pending→in_progress→completed, visible in `tm-agent task list`.

## T3 — docs

- This file (contract pointer; do NOT copy the schema — link it).
- After T2 lands: add a short "panel runs appear on the task board" note to the Team agent
  system section of CLAUDE.md (writer-owned, one paragraph max).

## T4 — tests

Socket e2e in `tests_v2/` (per `tests/CLAUDE.md`, VM-only):

1. `events.publish {kind:"xk_run", …}` → subscriber with `kinds:["xk_run"]` receives it < 1s.
2. Default-filter subscriber receives nothing for the same publish.
3. Oversized `tail` is truncated to 512 bytes in the delivered event.
4. (after T2) xk-bridge task mirroring happy path.

## Boundaries (term-mesh side)

**Always:** keep `xk_run` opt-in on subscribe; validate and cap event sizes; stay off-main.
**Ask first:** merging the Phase-1 branch; any Swift/GUI surface for panel runs (explicitly
out of scope for Phase 2 — task-board visibility is the GUI story); new event kinds.
**Never:** persist or replay `xk_run` events in the daemon; let xk-bridge mutate anything
other than the task board and `.xm/` writeback paths; deliver `xk_run` to default filters.
