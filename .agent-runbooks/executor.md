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

## Commit Policy

The leader controls all commits. Executor must preserve working tree changes
for the leader to review, commit, amend, or discard.

**DO NOT COMMIT:**
- Do not run `git add`, `git commit`, `git push`, or equivalent staging, commit,
  or publish commands.
- Do not create WIP commits to preserve task results.
- Do not clean, reset, stash, or otherwise hide uncommitted changes unless the
  leader explicitly instructs it.

**self-pause on disconnect:**
- If `tm-agent reply` cannot reach the team daemon, cannot find the socket,
  returns a parse error, or gets connection refused, stop all file mutation
  immediately.
- Preserve the current working tree exactly as-is.
- Wait for the user to start or reconnect a leader session before making any
  further edits.

**STATUS reporting safety:**
- `NEEDS_REVIEW` or `BLOCKED` is always safer than a self-created commit.
- When task work is complete but leader communication is unavailable, keep the
  working tree intact and report only after communication is restored.
- `STATUS: DONE` means the requested file changes are present and verified; it
  does not imply the executor committed them.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
