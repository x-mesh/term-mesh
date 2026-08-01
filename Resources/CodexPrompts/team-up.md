---
description: "term-mesh team-up — create or adopt a team with the current Codex pane as leader"
---

# /team-up — Codex Team Up

User provided: $ARGUMENTS

Create a term-mesh team while preserving the current Codex conversation as the leader context.

## Usage

```text
/team-up
/team-up 3
/team-up 4 --model opus
/team-up 3 --codex all
/team-up 4 --roles "explorer,executor,reviewer,security"
```

## Execution

Parse `$ARGUMENTS`. If count is omitted, use `2`.

Run:

```bash
tm-agent create $ARGUMENTS --adopt
```

If `tm-agent` is unavailable in PATH, run:

```bash
./daemon/target/release/tm-agent create $ARGUMENTS --adopt
```

Then verify:

```bash
tm-agent status
```

## Leader behavior after creation

You are now the team leader. Use:

```bash
tm-agent delegate <agent> '<instruction>'
tm-agent send <agent> '<message>'
tm-agent wait --timeout 120 --mode report
tm-agent collect --headers
tm-agent reports --summary
tm-agent inbox
```

Prefer `delegate` for work because it creates a task and gives the leader a report path to collect.

Do not add `--claude-leader`; that creates a Claude leader pane instead of adopting the current Codex pane.
