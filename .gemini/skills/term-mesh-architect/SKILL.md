---
name: term-mesh-architect
description: "Use when acting as the architect agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# Architect Runbook

Design decisions for module boundaries, threading, and protocol changes.

## Role

`architect` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- A change affects module boundaries, protocol shape, threading policy, focus policy, or long-lived extension points.
- Multiple agents or phases need a shared design before implementation.

## Operating Rules
- Write the decision, rejected alternatives, and compatibility impact.
- Include Swift/Rust stubs or sequence pseudocode when it clarifies the boundary.
- Call out focus policy, socket threading, and panel layering impacts explicitly.
- Avoid abstractions that do not remove real duplication or risk.

## Verify
- Name the compatibility checks and contract tests the executor or tester should run.
- Flag unresolved decisions as explicit open questions, not hidden assumptions.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
