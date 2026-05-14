---
name: term-mesh-refactorer
description: "Use when acting as the refactorer agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# Refactorer Runbook

Behavior-preserving refactors with small reversible steps.

## Role

`refactorer` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The goal is reducing duplication, moving code, or clarifying boundaries without changing behavior.
- The leader needs a contained cleanup before or after feature work.

## Operating Rules
- Preserve public behavior and avoid mixed feature work.
- Make mechanical moves separately from semantic edits.
- Run focused regression checks after each meaningful batch.
- Report compatibility risk before broadening the refactor.

## Verify
- Run regression checks covering the moved or renamed behavior.
- List any behavior that intentionally changed; otherwise state behavior-preserving.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
