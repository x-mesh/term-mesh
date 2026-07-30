# x-kit (xm plugins) integration

term-mesh integrates with the [xm plugin marketplace](https://github.com/x-mesh/xm)
(structured multi-agent orchestration for Claude Code; formerly `x-mesh/x-kit`). The
**single source of truth for the integration contract** — backend detection, fan-out
substitution rules, the `XK_TASK`/`XK_CORR` reply-header contract, and the component map —
lives in the xm repo:

> `xm/docs/term-mesh-integration.md`

The runtime rules agents actually need at execution time ship inside the plugins themselves
(`x-agent/skills/agent/references/term-mesh-backend.md`), so any session with the xm plugins
installed has them regardless of which repo is checked out.

## Runtime orchestration contract

`LeaderParallelPolicy` v1 is runtime-enforced from the canonical Swift source
`Sources/LeaderParallelPolicy.swift`. Local and peer leaders receive the same policy version and
SHA-256 digest; `team.status` exposes the source, version, digest, and injection state. A failed
or unverifiable injection is explicit `failed` state; policy guidance requires degraded situations
to be reported explicitly rather than silently falling back.

Substantive work is parallel-by-default, but only DAG-ready tasks may start: every dependency must
be `completed`; failed or blocked dependencies do not release a child. Local and peer agents are
ranked in one pool using placement and checkout metadata. Routing and observability preserve the
stable `task_id + agent_instance_id` key, including duplicate role/name rows. Ambiguous name-only
selection is rejected; unique-name callers remain compatible.

Auto-claim-next is exact-instance work stealing: the instance that completed work claims the next
ready unassigned task. Failed delivery releases that claim back to the unassigned pool. Concurrent
writes need ownership/worktree isolation only when they share a checkout; distinct peer/local
checkouts need no extra worktree, but pushes to one branch remain serialized. Machine-readable
telemetry carries routing IDs/digests/byte counts rather than prompt or result bodies. Hard-timebox
convergence uses completed evidence only and explicitly blocks, cancels, splits, or continues the
rest — a timeout is never success.

## What term-mesh provides

| Surface | Used for |
|---------|----------|
| `tm-agent delegate/fan-out/wait/collect` | executing xm skill fan-outs on persistent pane teams |
| app socket `set_status` / `set_progress` | live pane telemetry for x-kit phases (via x-kit `tm-bridge.mjs`) |
| daemon `events.publish` / `events.subscribe` | x-kit phase transitions on the daemon event bus |
| `tm-agent xk-bridge` | daemon `reply`/`task_status` events → `.xm/` writeback (generalizes `xmb-bridge`) |
| task board + kanban dashboard | mirrored x-build task DAG (`tm-agent task create --depends-on`) |

## Quick win: x-kit dashboard in a browser split

```bash
x-kit dashboard start          # bun server on 127.0.0.1:19841 over .xm/ state
term-mesh browser open http://127.0.0.1:19841
```

Shows traces, costs, op runs, solver state, and the x-build task DAG live beside the working
terminal.
