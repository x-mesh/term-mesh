---
description: Alias-style fan-out command for dispatching one instruction to the whole term-mesh team.
---

# tm All

User provided: $ARGUMENTS

This command follows the same workflow as `/tm:tm`. Use it when the user wants a readable alias for "send this to all relevant term-mesh agents."

## Preflight

Verify `tm-agent` exists and `tm-agent status` reports an active team. If no team exists, tell the user to run `/tm:up` first.

## Plan

If `$ARGUMENTS` is empty, show:

```text
/tm:all "ping"
/tm:all "review this diff"
```

Otherwise dispatch `$ARGUMENTS` as tracked work through term-mesh.

## Commands

Prefer the tracked work-pool path:

```bash
tm-agent task create '<instruction>'
tm-agent broadcast 'tm-agent claim'
tm-agent wait --timeout 300 --mode any
tm-agent collect --headers
tm-agent reports --summary
```

Use an explicit `--timeout <seconds>` from `$ARGUMENTS` when supplied.

## Verification

Use `tm-agent collect --headers` and `tm-agent reports --summary` before reading any full report files.

## Summary

Synthesize agent results in a short leader response. Mention blocked agents only when they affect the outcome.

## Next Steps

If agents produced code or instructions, verify locally before reporting success.
