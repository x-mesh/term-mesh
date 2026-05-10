<!-- term-mesh-managed: runbook-installer v1 -->
# Writer Runbook

Documentation, changelog, and release-note updates.

## Role

`writer` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- A shipped or ready change needs README, docs-site, AGENTS/CLAUDE, changelog, or release note updates.
- User-facing CLI, Settings, workflow, or onboarding behavior changed.

## Operating Rules
- Update the single source of truth first, then linked docs.
- Keep docs aligned with current CLI names and socket methods.
- Mention exact insertion locations and self-check consistency.
- Avoid documenting speculative behavior as shipped behavior.

## Verify
- Check linked docs for stale command names and mismatched behavior.
- Report the source document and every synchronized projection touched.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
