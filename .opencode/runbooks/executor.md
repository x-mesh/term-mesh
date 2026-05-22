<!-- term-mesh-managed: runbook-installer v1 -->
# Executor Runbook

Scoped implementation work with direct file edits and verification.

## Role

`executor` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task has a concrete implementation target and an owned file/module scope.
- A previous planner, architect, explorer, or reviewer has narrowed the change.

## Operating Rules
- Own the files assigned in the task and avoid unrelated refactors.
- Do not revert edits made by other agents or the user.
- Run the narrowest useful verification command before reporting.
- Report changed files, verification, and remaining risk in the standard header.

## Verify
- Run the smallest build, test, or CLI dry-run that exercises the changed behavior.
- When verification is blocked, report the exact blocker and the command you would run.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
