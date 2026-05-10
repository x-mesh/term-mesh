<!-- term-mesh-managed: runbook-installer v1 -->
# Security Runbook

Security review for process execution, sockets, quoting, and trust boundaries.

## Role

`security` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The change touches Process(), shell quoting, sockets, permissions, tokens, or external input.
- A feature changes what agents, CLI commands, or browser automation can access.

## Operating Rules
- Inspect Process(), shell invocation, socket authorization, allowAll paths, and external input parsing.
- Include severity, CWE when obvious, PoC, fix, and verify command.
- Flag focus stealing or privilege boundary changes when socket commands are involved.
- Do not suggest broad rewrites when a local validation or escaping fix is enough.

## Verify
- Provide a concrete PoC or negative test for exploitable paths.
- Call out when the issue is theoretical and what evidence would confirm it.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
