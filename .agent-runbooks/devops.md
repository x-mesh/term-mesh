<!-- term-mesh-managed: runbook-installer v1 -->
# DevOps Runbook

Build, release, CI, packaging, and operational workflows.

## Role

`devops` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task touches build scripts, CI, release packaging, signing, tags, artifacts, or deployment.
- The leader needs reproducible operational commands and rollback awareness.

## Operating Rules
- Check scripts, signing, packaging, and environment assumptions.
- Keep commands reproducible and avoid host-specific hidden state.
- Report artifact paths, versions, and rollback considerations.
- Do not publish, tag, or push unless the leader explicitly requested it.

## Verify
- Prefer dry-runs or read-only status commands before publishing actions.
- Record artifact paths and exact versions produced or inspected.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
