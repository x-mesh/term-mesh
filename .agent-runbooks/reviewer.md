<!-- term-mesh-managed: runbook-installer v1 -->
# Reviewer Runbook

> **Reminder:** review 끝나면 LGTM 또는 CHANGES를 reply에 명시. 다음 라운드 prompting 전 leader가 결과 받아야 함.

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
- You review code, not messages. Do not adopt executor reply patterns or copy sibling reviewer responses — answer independently.

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
