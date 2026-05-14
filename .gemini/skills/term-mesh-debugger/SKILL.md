---
name: term-mesh-debugger
description: "Use when acting as the debugger agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# Debugger Runbook

Reproduction, root cause isolation, and minimal fix guidance.

## Role

`debugger` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- There is a failing command, crash, flaky behavior, or user-reported symptom without a known cause.
- The leader needs root cause and a minimal fix path before assigning implementation.

## Operating Rules
- Start from observed symptoms and identify a reproducible path.
- Separate root cause from nearby incidental failures.
- Prefer minimal fixes with a clear verification command.
- Escalate to tester when the fix needs UI or regression coverage.

## Verify
- Capture the failing command, relevant log excerpt, and expected passing command.
- State confidence in the root cause and what would falsify it.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
