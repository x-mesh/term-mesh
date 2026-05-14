---
description: Manage term-mesh teams, agents, messages, and task board state through tm-agent.
---

# tm Team

User provided: $ARGUMENTS

Use this command for term-mesh team lifecycle and direct team operations.

## Preflight

1. Locate `tm-agent` on `PATH`, or fall back to `./daemon/target/release/tm-agent`.
2. Do not use Codex native sub-agents or disconnected team APIs.
3. Treat term-mesh daemon state as authoritative.

## Plan

If `$ARGUMENTS` is empty, print this cheat sheet and stop:

```text
/tm:team status
/tm:team create 3 --adopt
/tm:team attach reviewer
/tm:team delegate explorer "find all call sites of X"
/tm:team task list
/tm:team collect --headers
/tm:team destroy
```

For non-empty input, map the request to `tm-agent` operations.

## Commands

Common mappings:

```bash
tm-agent status
tm-agent list
tm-agent create 3 --adopt
tm-agent attach reviewer
tm-agent detach reviewer
tm-agent delegate explorer '<instruction>'
tm-agent send explorer '<message>'
tm-agent broadcast '<message>'
tm-agent task list
tm-agent task create '<title>' --assign <agent>
tm-agent collect --headers
tm-agent reports --summary
tm-agent destroy
```

For a command-like `$ARGUMENTS`, pass through to `tm-agent` after preserving shell quoting.

## Verification

For lifecycle changes, verify with:

```bash
tm-agent status
tm-agent list
```

For delegated work, verify with:

```bash
tm-agent wait --timeout 120 --mode any
tm-agent collect --headers
```

## Summary

Report the exact `tm-agent` action performed and the resulting team state.

## Next Steps

If a task was assigned, collect headers first and open full reports only for blocked or failed work.
