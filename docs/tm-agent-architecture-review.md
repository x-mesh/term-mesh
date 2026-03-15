# tm-agent System Architecture Review

> Reviewed: 2026-03-15
> Scope: daemon (term-meshd), CLI (tm-agent), Swift orchestration layer

---

## System Overview

The tm-agent system is a three-layer multi-agent coordination plane:

```
┌─────────────────────────────────────────────────────┐
│  macOS Swift App (term-mesh)                        │
│  TeamOrchestrator.swift  TerminalController.swift   │
│  DashboardController.swift  AgentRolePreset.swift   │
└──────────────────┬──────────────────────────────────┘
                   │ Unix socket JSON-RPC
┌──────────────────▼──────────────────────────────────┐
│  term-meshd (Rust, async Tokio)                     │
│  agent.rs (SQLite sessions)  socket.rs (RPC)        │
│  monitor.rs  watcher.rs  worktree.rs  tokens.rs     │
└──────────────────┬──────────────────────────────────┘
                   │ Unix socket JSON-RPC (~2ms)
┌──────────────────▼──────────────────────────────────┐
│  tm-agent (Rust CLI, ~2ms)                          │
│  tm_agent.rs — unified leader + worker CLI          │
└─────────────────────────────────────────────────────┘
```

---

## Strengths

1. **Latency**: tm-agent Rust binary achieves ~2ms per call vs ~10ms for the old bash fallback. Correct choice.

2. **Persistence**: AgentSessionManager uses SQLite for session state — survives daemon restarts and crash recovery. `detect_orphan_worktrees()` on startup is a good defensive pattern.

3. **Graceful shutdown**: Daemon shutdown sequence (signal servers → terminate agents → resume stopped processes → wait with timeout → cleanup socket) is well-structured.

4. **Socket security**: UID/PID verification in TerminalController+Process.swift prevents unauthorized socket access. Process ancestry check is a strong defense.

5. **Protocol abstraction (Phase 3-7 complete)**: Singleton coupling has been substantially removed. ServiceContainer + SwiftUI Environment injection is clean.

6. **P0 task lifecycle**: The task state machine (queued → assigned → in_progress → blocked → review_ready → completed/failed) is well-defined and matches real operational needs.

---

## Architectural Issues

### Issue 1: Dual State Stores (High)

**Problem**: Team state exists in two places simultaneously:
- `TeamOrchestrator.swift` — in-memory `[String: Team]` dict in the Swift app
- `team_state: TeamStateStore` in `socket.rs` — a raw `serde_json::Value` blob pushed by Swift

The daemon's `team_state` is a passive mirror with no schema enforcement. If the Swift app crashes mid-update, the daemon holds stale state. The CLI reads from the daemon; the Swift UI reads from `TeamOrchestrator`. These can diverge silently.

**Recommendation**: Make the daemon the authoritative source for task/team state. Swift should write to daemon via RPC and read back. The current pattern (Swift pushes a JSON blob, daemon stores it opaquely) is fragile.

### Issue 2: tm_agent.rs is a 46KB Monolith (Medium)

**Problem**: `tm_agent.rs` contains CLI parsing, RPC dispatch, team creation logic, prompt templates, and output formatting in a single 46KB file. The `agent.rs` daemon module is 56KB.

**Recommendation**: Split `tm_agent.rs` into:
- `cli.rs` — clap definitions only
- `rpc.rs` — socket communication
- `commands/` — one file per command group (task, msg, team, agent)
- `prompts.rs` — agent init/report prompt strings

### Issue 3: No Reconnect/Retry in tm-agent (Medium)

**Problem**: `tm_agent.rs` connects to the socket once and fails immediately if the daemon is unavailable. In practice, agents run in terminal panes where the daemon may restart.

**Recommendation**: Add a simple retry loop (3 attempts, 100ms backoff) before failing. The `rpc.rs` module already has the connection logic; wrap it.

### Issue 4: TeamOrchestrator.swift Still Has Builder Pattern Debt (Medium)

**Problem**: The March 9 architecture review identified `createTeam()` as having 300+ lines of nested closures. The refactoring status doc (Phases 1-7) covers singleton removal but does NOT address this. The function remains a deep nesting problem.

**Recommendation**: Apply the Builder pattern as specified in the original review. This is the highest-complexity remaining item in the Swift layer.

### Issue 5: P1 Stale Detection Not Implemented (Low-Medium)

**Problem**: The P0/P1 spec defines stale task detection based on heartbeat age, but `agent.rs` has no heartbeat timestamp tracking. The `last_progress_at` field exists in the task model but is not updated by `tm-agent heartbeat`.

**Recommendation**: Wire `tm-agent heartbeat` to update `last_progress_at` on the agent's active task in the daemon. Add a background task in term-meshd that marks tasks stale after a configurable threshold (default: 10 minutes).

### Issue 6: Shell Injection Risk in TeamOrchestrator (Low — but security)

**Problem**: Agent commands are built as shell strings:
```swift
let shellCommand = "\(agentCommand); exec $SHELL"
```
If `agentCommand` contains shell metacharacters, this is exploitable.

**Recommendation**: Use `Process` directly with `arguments` array. No shell interpolation needed. This was flagged in the March 9 review and remains unaddressed.

---

## P1 Implementation Gaps

| Feature | Status | Blocking? |
|---|---|---|
| Stale task detection | Not started | No |
| `tm-agent brief <agent>` | Not started | No |
| Task dependency auto-unblock | Not started | No |
| Workflow presets (Bug Triage, etc.) | Not started | No |
| Per-agent heartbeat tracking | Partial (field exists, not wired) | No |
| `wait --mode idle` | Not started | No |

---

## Recommended Priority Order

**P0 (fix now):**
1. Shell injection fix in `TeamOrchestrator.swift` — security, low effort
2. Wire `tm-agent heartbeat` to update `last_progress_at` on active task

**P1 (next sprint):**
3. Split `tm_agent.rs` into modules — maintainability
4. Add reconnect retry to tm-agent socket connection
5. Apply Builder pattern to `createTeam()` in TeamOrchestrator.swift

**P2 (backlog):**
6. Make daemon authoritative for team/task state (eliminate dual stores)
7. Implement stale detection background task in term-meshd
8. Implement `tm-agent brief <agent>`

---

## Summary

The tm-agent system is architecturally sound at the protocol level. The Rust daemon + SQLite + JSON-RPC design is correct. The main risks are: (1) dual state stores that can diverge, (2) shell injection in agent command building, and (3) growing file sizes in both the CLI and daemon that will impede future changes. The P0 task lifecycle is complete and working. P1 gaps are non-blocking but should be scheduled.
