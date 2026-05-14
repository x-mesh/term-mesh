---
name: tm
description: Use when the user wants term-mesh team orchestration from Codex, including tm-agent, /tm, /team, fan-out, delegation, leader workflows, task board work, or strategy orchestration.
---

# term-mesh Team Orchestration

Use this skill to route Codex team work through term-mesh.

## Core rule

When a term-mesh team is involved, use `tm-agent`. Do not use Codex native sub-agents or disconnected team state for term-mesh work.

## Command equivalents

In a normal Codex TUI, plugin slash commands are namespace-prefixed:

```text
/tm:tm "instruction"       # fan-out tracked work
/tm:all "instruction"      # fan-out alias
/tm:team status            # lifecycle and task board
/tm:up 3                   # create/adopt team
/tm:op review --target X   # structured strategy
```

Inside the term-mesh app IME, shorter aliases may be available:

```text
/tm
/team
/team-up
/tm-op
```

## tm-agent basics

```bash
tm-agent status
tm-agent list
tm-agent create 3 --adopt
tm-agent attach reviewer
tm-agent delegate explorer '<instruction>'
tm-agent task create '<title>'
tm-agent broadcast 'tm-agent claim'
tm-agent wait --timeout 120 --mode any
tm-agent collect --headers
tm-agent reports --summary
```

Always wait with `tm-agent wait`; do not use `sleep` as a polling substitute.

## Leader behavior

1. Keep the leader responsible for synthesis and final verification.
2. Use task-board operations for work that should produce a report.
3. Use direct messages only for lightweight coordination.
4. Read headers first, then open `FULL_REPORT` paths only when needed.
5. If no team exists, create/adopt with `/tm:up` or `tm-agent create ... --adopt`.

## Reply protocol

Expect agent replies to start with:

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed files or none>
VERIFY: <single verification command or n/a>
NEXT: <leader next action or NONE>
FULL_REPORT: <path or n/a>
```

Use the header to decide whether to verify locally, request fixes, or read the full report.
