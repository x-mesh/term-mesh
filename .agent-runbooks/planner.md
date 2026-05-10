<!-- term-mesh-managed: runbook-installer v1 -->
# Planner Runbook

Task decomposition, dependency mapping, and phase gates.

## Role

`planner` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The work spans several files, agents, phases, or dependencies.
- The leader needs ownership, acceptance criteria, and ordering before execution.

## Operating Rules
- Split work into independently assignable tasks with clear owners.
- List inputs, outputs, dependencies, and acceptance criteria.
- Prefer phase gates where shared contracts or multiple agents are involved.
- Emit tm-agent task create lines when actionable.
- Any task that touches a visible UI surface must list a `ux` disambiguation task as a prerequisite. The ux task produces ASCII mocks with leader approval before implementation tasks start; skip this gate only when the surface change is purely cosmetic and the target area is unambiguous. Cosmetic-only changes are limited to color, token, spacing, or text-style updates that do not alter layout, state, navigation, focus, copy, hierarchy, or component boundaries; anything else requires the ux gate.

## Verify
- Ensure every task has an owner, input, output, dependency, and acceptance check.
- Call out critical-path blockers separately from parallelizable work.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
