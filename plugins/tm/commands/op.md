---
description: Run structured term-mesh strategy orchestration with tm-agent.
---

# tm Strategy Orchestrator

User provided: $ARGUMENTS

Use this command when the team needs a structured strategy rather than a one-shot fan-out.

## Preflight

1. Locate `tm-agent` on `PATH`, or fall back to `./daemon/target/release/tm-agent`.
2. Verify an active team with `tm-agent status`.
3. If no active team exists, tell the user to run `/tm:up` first and stop.

## Plan

If `$ARGUMENTS` is empty, show this catalog and stop:

```text
Strategies:
  refine      rounds of diverge -> converge -> verify
  tournament  parallel competition plus selection
  chain       A -> B -> C pipeline
  review      multi-perspective code review
  debate      pro/con debate then judgment
  red-team    attack/defend hardening
  brainstorm  divergent ideas and optional vote
  distribute  split independent work and merge
  council     multi-agent deliberation
  research    board.jsonl cooperative exploration

Examples:
  /tm:op review --target Sources/Auth.swift
  /tm:op refine "Codex leader UX" --rounds 3
  /tm:op distribute "Analyze 6 Sentry issues"
```

For non-empty input, parse the first token as the strategy and route through `tm-agent` or the project-local strategy implementation.

## Commands

Preferred mapping:

```bash
tm-agent research '<topic>' --depth deep --budget 5
tm-agent task create '<split task>' --assign <agent>
tm-agent delegate <agent> '<instruction>'
tm-agent broadcast '<instruction>'
tm-agent wait --timeout <seconds> --mode any
tm-agent collect --headers
tm-agent reports --summary
```

For strategies already implemented by the Codex wrapper, follow `Resources/CodexPrompts/tm-op.md` and keep every team operation on `tm-agent`.

## Verification

Use:

```bash
tm-agent collect --headers
tm-agent reports --summary
```

Read full report files only when headers show `BLOCKED`, `NEEDS_REVIEW`, failed verification, or truncated output.

## Summary

Return the strategy used, participating agents, decision, and next action.

## Next Steps

If the strategy selected a patch or plan, execute the leader's next step locally and verify it.
