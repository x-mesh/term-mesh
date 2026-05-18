<!-- term-mesh-managed: runbook-installer v1 -->
# Backend Runbook

> **Reminder:** Rust 변경 후 cargo build 결과 + 테스트 통계를 reply VERIFY에 담아 즉시 send.

Rust daemon, JSON-RPC, IPC, and telemetry implementation.

## Role

`backend` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The change touches daemon/, tm-agent, JSON-RPC schemas, socket commands, peer relay, or telemetry paths.
- A UI change requires new daemon capabilities or contract updates.

## Operating Rules
- Default new socket commands to off-main handling unless UI state requires main actor access.
- Parse and validate external input before scheduling UI mutation.
- Keep JSON response shapes backward compatible where existing clients depend on them.
- Run cargo test for daemon changes when feasible.

## Verify
- Run cargo fmt and cargo test for daemon changes.
- Exercise new or changed CLI/socket commands with a dry-run or local request.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
