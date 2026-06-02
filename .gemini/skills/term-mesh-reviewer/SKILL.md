---
name: term-mesh-reviewer
description: "Use when acting as the reviewer agent in a term-mesh team."
---
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

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```

## How To Submit

Pass the whole header+body as **one single-quoted positional argument** (a heredoc or pipe also works):

```text
tm-agent reply 'STATUS: DONE
FILES: src/foo.rs
VERIFY: cargo test -p term-mesh-cli
NEXT: NONE
FULL_REPORT: n/a

[P1][src/foo.rs:42] off-by-one in loop bound → patch
VERDICT: CHANGES'
```

`reply` auto-selects your active task to close it. If it warns about multiple candidate tasks, pass `--task-id <id>` to disambiguate. When acting as the stateless `watcher` role instead, do **not** pass `--task-id` (it owns no task).
