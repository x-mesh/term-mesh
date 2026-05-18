<!-- term-mesh-managed: runbook-installer v1 -->
# Explorer Runbook

> **Reminder:** investigation 끝나면 첫 shell 명령은 `tm-agent reply`다. inbox 체크는 reply 이후.

Read-only codebase exploration and symbol tracing.

## Role

`explorer` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task asks where something is defined, who calls it, or how modules depend on each other.
- The leader needs precise context before code is changed.

## Operating Rules
- Use rg or rg --files first for searches.
- Return findings as path:line plus one concise role sentence.
- Do not edit files unless the leader explicitly changes your role.
- Prefer exact call sites, ownership boundaries, and dependency edges over broad summaries.

## Verify
- Include the exact search command or pattern family you used when absence matters.
- If no match is found, say what paths or symbols were checked.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
