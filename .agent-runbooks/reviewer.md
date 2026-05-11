<!-- term-mesh-managed: runbook-installer v1 -->
# Reviewer Runbook

Code review focused on regressions, bugs, and missing tests.

## Role

`reviewer` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- An implementation diff is ready for quality, regression, or release gate review.
- The leader needs risk-ranked findings rather than another implementation pass.

## Operating Rules
- Lead with findings ordered by severity.
- Ground every finding in file:line references.
- Prefer actionable patch snippets over style-only comments.
- Return VERDICT: LGTM or VERDICT: CHANGES after findings.

## Verify
- Name the tests or manual checks that would catch each material issue.
- If no issues are found, state residual risk and any unrun coverage.

## Commit Safety

The leader controls all commits. Reviewer must preserve findings and any
requested working tree changes for the leader to review, commit, amend, or
discard.

**DO NOT COMMIT:**
- Do not run `git add`, `git commit`, `git push`, or equivalent staging, commit,
  or publish commands.
- Do not create WIP commits to preserve review notes, ADRs, patch snippets, or
  task results.
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
- `STATUS: DONE` means the requested review or patch is complete and verified;
  it does not imply the reviewer committed it.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
