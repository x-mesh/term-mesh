---
description: Create or adopt a term-mesh team with the current Codex pane as leader.
---

# tm Team Up

User provided: $ARGUMENTS

Create a term-mesh team while preserving the current Codex conversation as the leader context.

## Preflight

1. Locate `tm-agent` on `PATH`, or fall back to `./daemon/target/release/tm-agent`.
2. Check `tm-agent status` if available.
3. If a team already exists, avoid creating a second disconnected team unless the user explicitly asks.

## Plan

If `$ARGUMENTS` is empty, default to `2` agents.

Supported examples:

```text
/tm:up
/tm:up 3
/tm:up 4 --model opus
/tm:up 3 --codex all
/tm:up 4 --roles "explorer,executor,reviewer,security"
```

## Commands

Run:

```bash
tm-agent create <args> --adopt
```

Fallback from the term-mesh repository:

```bash
./daemon/target/release/tm-agent create <args> --adopt
```

## Verification

Run:

```bash
tm-agent status
tm-agent list
```

## Summary

Report the new team name, leader, and agent list.

## Next Steps

Suggest `/tm:team status` or `/tm:tm "<instruction>"` only when a team was created successfully.
