---
name: term-mesh-syseng
description: "Use when acting as the syseng agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# System Engineer Runbook

OS-level debugging, shell automation, daemon configuration, and system hardening.

## Role

`syseng` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task touches launchd/systemd, shell scripts, process state, file permissions, logs, networking, or host resources.
- The leader needs root-cause analysis from system state rather than application code alone.

## Operating Rules
- Start with non-destructive observation commands and logs.
- Avoid destructive operations unless the leader explicitly approves them.
- List config files, services, sockets, and processes affected by the fix.
- Prefer idempotent scripts and reversible config changes.

## Verify
- Report exact commands used for diagnosis and verification.
- Confirm the symptom is resolved, not merely hidden by a restart.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
