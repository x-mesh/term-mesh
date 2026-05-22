# ARCHITECTURE Lens Code Review — Watch Phase 2 (watcher Diff)

**Diff Range:** `20e2c2378f2d8122c08a9724b80e2b56b14f16c5..86650317`

**Review Date:** 2026-05-20

**Reviewer:** architect

**Status:** Complete

---

## Executive Summary

The watch Phase 2 diff introduces a new autonomous drift-watch scheduler and controller across 5 new/modified modules:
- `daemon/term-meshd/src/watch.rs` (scheduler, Phase 4)
- `daemon/term-meshd/src/watch_controller.rs` (result handler, Phase 5)
- `daemon/term-meshd/src/socket.rs` (RPC handlers + context setup)
- `daemon/term-meshd/src/socket/watch_config.rs` (persistence, Phase 6)
- `Sources/TeamOrchestrator.swift` + `Sources/TerminalController.swift` (Swift agent schema updates)

**Architecture Review Focus:**
- Module boundaries (watch scheduler ↔ watch_controller ↔ socket)
- RPC/IPC schema consistency (Swift agent tuple shape vs. watcher-specific fields)
- Ownership & single-writer contracts (board.jsonl, inbox)
- Config persistence vs. in-memory registry synchronization
- SRP & circular dependencies

**Finding Summary:**
- **6 Medium-severity findings** (all architectural/design; no runtime bugs in current flow)
- **1 Low-severity finding** (code cleanliness)
- **No High or Critical issues**

---

## Detailed Findings

### [MEDIUM] WatchCheckOutcome — Missing Working Directory & Socket Path

**Location:** `daemon/term-meshd/src/watch_controller.rs:336–341` (handle_outcome function)

**Problem:**

The `WatchCheckOutcome` structure (defined in `headless::one_shot`) does not include `working_directory` or `app_socket_path`. The controller must retrieve these from the shared `WatchRegistry` on every outcome:

```rust
let (working_dir, app_socket) = {
    let reg = registry.lock().await;
    match reg.get(&outcome.team_id) {
        Some(st) => (st.working_directory.clone(), st.app_socket_path.clone()),
        None => (String::new(), None),  // ← Loses context silently
    }
};
if working_dir.is_empty() {
    tracing::warn!("watch: no registry working_dir for team {} — skipping board/inbox", 
                   outcome.team_id);
    continue;  // Silent skip on deregistration race
}
```

**Risk:** If the team is removed from the registry (via `watch.off`) before the outcome is processed, the controller silently skips the board write and inbox post with only a warning log. The drift verdict is lost, the leader never hears about it, and there's no signal that the outcome was discarded.

**Root Cause:** The outcome type is owned by Phase 1/4 (`headless::one_shot`), but Phase 5 (controller) needs team-scoped context. The two phases aren't coupled via the type, so context is resolved post-hoc.

**Architectural Coupling:** watch → watch_controller depends on registry entry existing at outcome-processing time.

**Recommended Fix:**

*Option A (Preferred):* Include `working_directory` and `app_socket_path` in `WatchCheckOutcome` at creation time (in the scheduler when the check is triggered). This makes the outcome self-contained and idempotent.

*Option B:* Ensure the registry entry is pinned for the outcome's lifetime via a reference-counted guard pattern; the scheduler holds a ref until the outcome is consumed.

---

### [MEDIUM] Config Persistence ↔ Registry — One-Way Sync Only

**Location:** `daemon/term-meshd/src/socket.rs:1931` (watch.status RPC handler)

**Problem:**

The watch config lifecycle has two separate states:
1. **`.xm/watch/config.json`** — persisted on disk; survives daemon restart.
2. **`WatchRegistry`** — in-memory; populated at daemon startup via `load_watch_states()`.

At startup, `main.rs` calls `load_watch_states()` to sync config.json → registry. At runtime, `watch.on` and `watch.off` sync registry → config.json. However, there is no on-demand reload path:

- User configures watch: `watch.on(team_id, ...)` → persisted to config.json, in-memory registry updated.
- Daemon crashes and restarts; watch is re-registered from config.json.
- **Runtime scenario:** If a user manually edits config.json while the daemon is running (e.g., via a script), the in-memory registry stays stale until the daemon restarts.

Additionally, `watch.status` returns the in-memory registry state. When the registry is empty, there's no distinction between:
- "No watches ever configured" vs. "Watches configured but all disabled"

The disabled watches might still exist in config.json but aren't visible to the user until they restart the daemon.

**Root Cause:** Unidirectional sync + no reload command.

**Architectural Coupling:** socket handlers ↔ config.json, but no explicit sync boundary.

**Recommended Fix:**

*Option A (Preferred):* Add a `watch.reload` RPC handler that explicitly re-loads `.xm/watch/config.json` into the in-memory registry, allowing runtime synchronization.

*Option B:* Document the one-way sync contract explicitly and warn users against manual runtime edits of config.json.

---

### [MEDIUM] Board Idempotency — O(n) Deduplication Per Append

**Location:** `daemon/term-meshd/src/watch_controller.rs:158–170` (append_board_finding) + `daemon/term-meshd/src/socket.rs:30–43` (board_drift_count)

**Problem:**

Deduplication by `check_id` requires reading the entire `board.jsonl` file on every append:

```rust
pub(crate) fn append_board_finding(
    working_dir: &Path,
    f: &BoardFinding,
) -> std::io::Result<bool> {
    // ... create_dir ...
    let path = dir.join("board.jsonl");
    
    if path.exists() {
        let content = std::fs::read_to_string(&path)?;  // ← Read entire file
        for line in content.lines() {
            // ← Scan all lines looking for check_id
            if v.get("check_id").and_then(|x| x.as_str()) == Some(f.check_id.as_str()) {
                return Ok(false);  // Found; skip
            }
        }
    }
    // ... append to file ...
}
```

The `watch.status` RPC also duplicates this work via `board_drift_count()` to compute the number of distinct drift checks. Over time:
- Day 1: 10 findings → 10 lines in board.jsonl; each append reads 10 lines. Cost: O(10).
- Month 6: 10,000 findings → 10,000 lines; each append reads all 10,000. Cost: O(10,000).

A team with checks every 5 minutes over 6 months accrues ~52,000 lines. A single drift outcome then requires reading 52,000 lines, parsing JSON on each, and searching for a match.

**Root Cause:** JSONL is inherently append-only. Deduplication requires an index that doesn't exist.

**Performance Impact:** Slow append, slow status reads. No immediate failure, but degradation over months of operation.

**Recommended Fix:**

*Option A (Preferred):* Maintain a companion `.check_ids` file — one `check_id` per line, sorted — to enable O(log n) lookup before reading the full board.jsonl.

*Option B:* Cache the set of recent `check_id`s in the `WatchRegistry` itself. When a finding is appended, update the cache. When `watch.status` queries the count, derive it from the cached check_ids.

*Option C:* Use a SQLite database instead of JSONL for board entries (complex; may be overkill).

---

### [MEDIUM] Single-Writer Contract for board.jsonl — Not Type-Enforced

**Location:** `daemon/term-meshd/src/watch_controller.rs:5–8` (module doc comment)

**Problem:**

The module documentation states:

```rust
//! Boundaries:
//! - **F2** — the watcher subprocess itself never writes the board or messages
//!   anyone; this controller is the single writer.
```

However, this contract exists only as documentation. Nothing in the type system prevents:
1. A future socket RPC handler from also calling `append_board_finding()`.
2. A test from creating two `run_watch_controller` instances (with different inboxes) writing to the same board.jsonl concurrently.
3. External code with filesystem access from directly writing to board.jsonl.

The contract is aspirational, not enforced.

**Risk:** If the single-writer invariant is violated (e.g., two controllers or an RPC handler also writes), duplicate rows or corrupted check_ids could accumulate in the board.

**Root Cause:** `append_board_finding()` is public (crate-level); any module can call it. The board path itself is computed locally (not private).

**Architectural Pattern Violation:** Violates encapsulation. The board is a shared resource with a single producer, but that constraint isn't visible in the code structure.

**Recommended Fix:**

Encapsulate board writes behind a single `BoardWriter` type that the controller exclusively owns:

```rust
pub(crate) struct BoardWriter {
    working_dir: PathBuf,
}

impl BoardWriter {
    pub async fn append(&mut self, f: &BoardFinding) -> std::io::Result<bool> { /* ... */ }
}

pub async fn run_watch_controller<I: LeaderInbox + 'static>(
    mut rx: mpsc::UnboundedReceiver<WatchCheckOutcome>,
    registry: crate::drift_watch::WatchRegistry,
    inbox: I,
) {
    let mut board_writer = BoardWriter::new(...);  // Created once, held exclusively
    // ...
}
```

If other code (e.g., watch.status RPC) needs to read the board, expose a read-only method on `BoardWriter`.

---

### [MEDIUM] RPC Schema Entanglement — customInstructions on All Agents

**Location:** `Sources/TerminalController.swift:2051–2063` (team.create RPC)

**Problem:**

The agent tuple shape was updated to include `customInstructions`:

```swift
let agents = agentsParam.map { dict -> (
    name: String,
    cli: String,
    model: String,
    agentType: String,
    color: String,
    instructions: String,
    customInstructions: String  // ← New field
) in
    (
        name: dict["name"] as? String ?? "agent",
        // ...
        instructions: dict["instructions"] as? String ?? "",
        customInstructions: dict["custom_instructions"] as? String ?? ""
    )
}
```

However, the diff's comment (R7) explicitly states:

```swift
// R7: only the watcher carries custom_instructions (the CLI
// attaches `--spec` to the watcher dict only). composeInstructions
// appends it verbatim as `## Team Custom Instructions`.
```

So the field is meaningful only for the watcher agent, but it's now part of the generic agent tuple used for *all* agent types (reviewer, executor, security, etc.). This couples a watcher-specific concern into the RPC schema.

**Risk:** Future maintainers might assume the field applies to all agents. It could be accidentally used for non-watcher agents, or the spec text could leak into non-watcher instructions.

**Root Cause:** The agent tuple shape is a generic data structure shared across all agent types. Watcher-specific fields were added at the schema level rather than isolated.

**Architectural Pattern Violation:** Violates separation of concerns. The agent schema should not carry watcher implementation details.

**Recommended Fix:**

*Option A (Preferred):* Separate the watcher configuration into its own RPC or a sub-field:

```swift
// Option A1: Separate watcher RPC
await callV2RPC("team.configure_watch", {
    "team_id": ...,
    "spec": ...,
})

// Option A2: Nested watcher config in agent dict
{
    "agent_type": "watcher",
    "name": "watcher",
    "watcher_config": {
        "spec": "..."
    }
}
```

*Option B:* Document explicitly near the agent tuple definition why only the watcher uses this field, with a prominent code comment and a type wrapper to make the intent clear:

```swift
struct AgentTuple {
    let name, cli, model, agentType, color, instructions: String
    /// Watcher-only: the oversight spec. Used only when agentType == "watcher".
    /// Other agent types must leave this empty.
    let customInstructions: String
}
```

---

### [MEDIUM] Missing app_socket_path Fallback

**Location:** `daemon/term-meshd/src/watch_controller.rs:297–301` (AppSocketInbox::post)

**Problem:**

When `app_socket` is None, the controller logs a warning and silently returns:

```rust
pub async fn post_team_message(
    app_socket: &str,
    team_id: &str,
    content: &str,
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::UnixStream::connect(app_socket).await?;
    // ...
}

impl LeaderInbox for AppSocketInbox {
    fn post<'a>(
        &'a self,
        team_id: &'a str,
        content: &'a str,
        app_socket: Option<&'a str>,
    ) -> InboxFuture<'a> {
        let Some(sock) = app_socket else {
            tracing::warn!("watch: no app socket — leader inbox skipped (team {team_id})");
            return;  // ← Silent skip
        };
        // ...
    }
}
```

In the context of `handle_outcome()`:

```rust
match append_board_finding(working_dir, &finding_row) {
    Ok(true) => {
        // Drift finding written to board; now notify the leader.
        inbox.post(&outcome.team_id, &content, app_socket).await;
        ControllerAction::Appended  // ← Success, even if post silently failed
    }
    // ...
}
```

**Risk:** The drift verdict is recorded in `board.jsonl`, but the leader's inbox message is silently skipped if `app_socket` is None. The leader has no way to know a drift was detected. There's no flag in the outcome to indicate post failure, no retry mechanism, and no visibility in `watch.status` about why the leader wasn't notified.

**Root Cause:** `app_socket_path` is optional in `WatchState`, but there's no fallback when it's missing.

**Recommended Fix:**

*Option A (Preferred):* Make `app_socket_path` mandatory at watch-enable time. When the user calls `watch.on`, validate that `app_socket_path` is provided and non-empty. Fail the RPC with a clear error message if it's missing.

*Option B:* Track inbox-post status in the outcome. Return a tuple `(appended: bool, inbox_ok: bool)` from `handle_outcome`, and expose `inbox_ok` in `watch.status` so the leader can diagnose why they didn't get notified.

*Option C:* Provide a fallback notification mechanism (e.g., write to a `.xm/watch/notifications.jsonl` file that the leader can poll).

---

### [MEDIUM] Cost Guard Enforcement — Scattered Location

**Location:** `daemon/term-meshd/src/socket.rs:1833–1844` (watch.on RPC handler)

**Problem:**

The minimum watch interval cost guard (`MIN_WATCH_INTERVAL_SECS = 30`) is enforced only in the RPC handler:

```rust
const MIN_WATCH_INTERVAL_SECS: u64 = 30;

// In watch.on RPC handler:
let requested_interval = if p.interval_secs == 0 {
    0
} else {
    p.interval_secs.max(MIN_WATCH_INTERVAL_SECS)  // ← Guard applied here
};
```

However, the `WatchState::enabled` constructor does not apply this guard:

```rust
pub fn enabled(
    interval_secs: u64,
    // ... other fields ...
) -> Self {
    Self {
        enabled: true,
        interval_secs: if interval_secs == 0 {
            DEFAULT_WATCH_INTERVAL_SECS
        } else {
            interval_secs  // ← No cost guard here; accepts any value
        },
        // ...
    }
}
```

Tests construct `WatchState` directly with tiny intervals:

```rust
#[tokio::test(start_paused = true)]
async fn watch_interval_ticks_without_sleeping() {
    let st = WatchState::enabled(
        1,  // ← 1 second, bypasses the 30s guard
        Some("executor".into()),
        // ...
    );
    // ...
}
```

**Risk:** The cost guard is meant to prevent LLM calls every few seconds (expensive). If code directly constructs `WatchState::enabled(5, ...)` (as tests do), the guard is silently bypassed. This could accidentally spread to production if a developer copies test patterns.

**Root Cause:** Guard logic is split: constructor handles defaults, RPC handler applies the cost guard. No single source of truth.

**Architectural Pattern Violation:** Constraint logic is scattered, making it easy to violate accidentally.

**Recommended Fix:**

Move the cost guard into `WatchState::enabled`, making it apply to all construction paths:

```rust
pub fn enabled(
    interval_secs: u64,
    // ...
) -> Self {
    let safe_interval = if interval_secs == 0 {
        DEFAULT_WATCH_INTERVAL_SECS
    } else {
        interval_secs.max(MIN_WATCH_INTERVAL_SECS)  // ← Guard applied universally
    };
    Self {
        enabled: true,
        interval_secs: safe_interval,
        // ...
    }
}
```

Document in the constructor that intervals < 30s are only valid for tests and will be clamped in production. If tests need sub-30s intervals, provide a separate `#[cfg(test)]` constructor or use the registry directly.

---

### [LOW] Hardcoded Path Duplication

**Location:**
- `watch_controller.rs:145` — `working_dir.join(".xm").join("watch")`
- `socket.rs:48` — (board_drift_count function)
- `socket/watch_config.rs:24` — `working_dir.join(".xm").join("watch").join("config.json")`

**Problem:**

The path `.xm/watch/` is hardcoded in multiple places. If the path ever changes (e.g., `.xm/v2/watch/` for a future version), it must be updated in all locations.

**Root Cause:** No shared constant or path builder function.

**Recommended Fix:**

Define centralized path builders in `watch.rs`:

```rust
// watch.rs
pub const WATCH_DIR: &str = ".xm/watch";

pub fn watch_dir(working_dir: &Path) -> PathBuf {
    working_dir.join(WATCH_DIR)
}

pub fn watch_board_path(working_dir: &Path) -> PathBuf {
    watch_dir(working_dir).join("board.jsonl")
}

pub fn watch_config_path(working_dir: &Path) -> PathBuf {
    watch_dir(working_dir).join("config.json")
}
```

Then use these in `watch_controller.rs` and `socket/watch_config.rs` instead of hardcoding the path.

---

## Summary Table

| Finding | Severity | Location | Impact | Fix Effort |
|---------|----------|----------|--------|-----------|
| WatchCheckOutcome context loss | MEDIUM | watch_controller.rs:336 | Silent outcome drop on deregister race | Medium |
| Config sync one-way | MEDIUM | socket.rs:1931 | Manual config edits invisible until restart | Medium |
| Board append O(n) | MEDIUM | watch_controller.rs:158 | Perf degrades over months | Medium |
| Single-writer untyped | MEDIUM | watch_controller.rs:5 | Contract violation risk | Medium |
| RPC schema entanglement | MEDIUM | TerminalController.swift:2051 | Watcher concern leaks into agent schema | Low |
| Missing socket fallback | MEDIUM | watch_controller.rs:297 | Silent notification loss if socket missing | Medium |
| Cost guard scattered | MEDIUM | socket.rs:1833 | Guard bypass risk in direct construction | Low |
| Path duplication | LOW | Multiple files | Future refactor friction | Low |

---

## Recommendations

**Before Production Scale-Up:**
1. **Priority 1:** Address WatchCheckOutcome context loss (risk of silent drift drops).
2. **Priority 2:** Implement board append indexing to prevent O(n) degradation.
3. **Priority 3:** Enforce single-writer contract via encapsulation.

**Medium Term:**
4. Add `watch.reload` RPC for runtime config sync.
5. Resolve RPC schema entanglement (separate watcher config).
6. Implement app_socket fallback or validation.

**Nice-to-Have:**
7. Consolidate cost guard logic.
8. Deduplicate path constants.

---

## Code Review Assessment

**Overall Assessment:** Architectural design is sound for Phase 2's scope, but has several Medium-severity structural issues that should be resolved before the system is scaled to many teams or long-term operation.

- **Module Boundaries:** Clear (watch → watch_controller → socket). Missing some field passthrough (outcome context).
- **Contracts:** Well-documented but not type-enforced (single-writer).
- **Persistence:** One-way sync; no reload path.
- **Performance:** Linear deduplication cost; fine for MVP, but needs indexing at scale.
- **Schema Coupling:** Minor (watcher-specific fields in generic agent tuple).

**No High or Critical Issues.** All findings are Medium or Low severity and do not prevent Phase 2 from functioning correctly in the current flow.

