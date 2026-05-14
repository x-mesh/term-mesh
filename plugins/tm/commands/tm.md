---
description: Fan out one instruction to idle term-mesh agents and synthesize the result.
---

# tm Fan-out

User provided: $ARGUMENTS

Use this command as the Codex plugin equivalent of the term-mesh `/tm` workflow.

## Preflight

1. Check whether `tm-agent` is available on `PATH`.
2. If it is not available, try `./daemon/target/release/tm-agent` from the current repository.
3. Verify that a term-mesh team exists with `tm-agent status`.
4. If there is no active team, tell the user to run `/tm:up` first and stop.

Do not use Codex native sub-agents for this workflow. The source of truth is the term-mesh daemon and `tm-agent`.

## Plan

If `$ARGUMENTS` is empty, show this short usage block and stop:

```text
/tm:tm "review Sources/Auth.swift"
/tm:tm "compare these approaches" --timeout 120
/tm:team status
/tm:up 3
```

For non-empty input:

1. Parse the instruction from `$ARGUMENTS`.
2. Parse optional `--timeout <seconds>`; default to `300`.
3. Dispatch the instruction as tracked work to available agents.
4. Wait with `tm-agent wait`.
5. Collect header summaries first, then read full reports only when needed.
6. Return a concise synthesis to the user.

Reject unsupported orchestration flags such as `--rounds`, `--agents`, or `--mode`; direct the user to `/tm:op` for strategy workflows.

## Commands

Use `tm-agent task create` plus `tm-agent broadcast 'tm-agent claim'` when the work should be claimed autonomously by idle agents:

```bash
tm-agent task create '<instruction>'
tm-agent broadcast 'tm-agent claim'
tm-agent wait --timeout <seconds> --mode any
tm-agent collect --headers
tm-agent reports --summary
```

If the user's wording explicitly asks every agent to respond, use:

```bash
tm-agent broadcast '<instruction>'
tm-agent wait --timeout <seconds> --mode any
tm-agent collect --headers
tm-agent reports --summary
```

Never implement waiting with `sleep`; use `tm-agent wait`.

## Verification

Confirm the output came through the term-mesh protocol:

```bash
tm-agent collect --headers
```

If a report is truncated or `FULL_REPORT` points to a file, read the specific file under `~/.term-mesh/results/`.

## Summary

Return:

```text
STATUS: done|partial|blocked
AGENTS: <who responded>
RESULT: <concise synthesis>
NEXT: <one concrete next step or NONE>
```

## Next Steps

If the leader needs to act on results, run the requested verification or implement the chosen patch locally.
