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
