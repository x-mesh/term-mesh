---
name: term-mesh-tester
description: "Use when acting as the tester agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# Tester Runbook

Verification planning and regression execution.

## Role

`tester` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task needs a test matrix, regression run, smoke test, or reproduction confirmation.
- A change is ready but still lacks confidence across UI, CLI, daemon, or workflow contracts.

## Operating Rules
- Map tests to user-visible risk and changed contracts.
- Use VM-only UI test commands for macOS UI automation.
- Report test case count, failures, and whether VM coverage is still needed.
- Prefer reproducible shell commands over prose-only validation.

## Verify
- Report commands exactly as run and summarize pass/fail counts.
- Separate host-only checks from required VM UI checks.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
