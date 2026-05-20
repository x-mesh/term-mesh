# ADR: Watch Drift Leader Visibility — inbox kind:watch_drift + attention_count

**Decision Date:** 2026-05-20  
**Status:** PROPOSED  
**Scope:** Phase 5 (watch_controller) + Socket RPC + Swift inbox  
**Read-Only Design (no code modifications)**

---

## Context

Watch drift verdicts currently post to the leader inbox via `team.message.post` with `type: "note"`. This message type is silently included in the message log but doesn't elevate in the inbox with high priority. The leader has no strong visual signal that a drift has occurred.

### Current Flow
1. `watch_controller.rs`: outcome → drift verdict parse → `post_team_message()` RPC with `type: "note"`
2. `TerminalController.swift`: `teamDataMessagePost()` → stores as message, no special inbox elevation
3. `TeamDataStore.inboxItems()`: message filtering by type (blocked, review_ready, error, etc.) — "note" type is excluded unless agent-specific
4. Sidebar attentionCount: derived from inbox items; currently only tasks and specific message types contribute

**Gap:** Drift findings (high-value, actionable) are recorded but don't surface in leader inbox with appropriate priority. The leader must actively scan message logs to see them.

---

## Decision

Extend the inbox system to support a new item `kind: "watch_drift"` with:

1. **Explicit kind:** `"watch_drift"` (alongside existing "task" and "message")
2. **Priority:** 2 (high, below blocked tasks but above review-ready; drifts are oversight-blocking issues)
3. **Idempotency:** Use `check_id` as the deduplication key (prevent duplicate inbox items for retried checks)
4. **Visibility:** Contribute to `attention_count` so the sidebar badge updates automatically
5. **Data Model:** Separate from message log; stored in a new `watchDrifts` dict in `TeamDataStore`
6. **Focus-Safe:** No app activation or window.focus side effects (data-only RPC, socket threading policy compliant)

---

## Rationale

### Why a new `kind` instead of message type `watch_drift`?
- **Separation:** Drift items have metadata (check_id, drift_type, severity) distinct from free-form messages.
- **Priority:** Inbox priority logic is kind-specific; watch drift deserves its own priority slot.
- **Idempotency:** Message log assumes each post is a new event; watch drift needs deduplication by `check_id`.

### Why priority 2?
- **Blocked tasks** (priority 1) are runner-blocking; drifts are oversight signals (similar priority).
- **Drifts** are actionable issues that require human attention within a session.
- Alternative: priority 1.5 if fine-grained, but integer for simplicity.

### Why check_id for dedup?
- Scheduler may retry a check if the first attempt times out or partially fails.
- Same `check_id` means same verdict; re-posting to inbox would duplicate the signal.
- `check_id` is already deterministic (SHA256 of team/target/spec/timestamp/count) so idempotency is stable across retries.

### Why separate from message log?
- Messages are audit-trail events; drifts are state snapshots.
- Messages append unconditionally; drifts upsert by `check_id`.
- Future: drifts can be cleared/acknowledged separately from message history.

---

## Architecture

```
                          daemon (Rust)
                          ─────────────
watch_controller.rs
  ├─ outcome received (from scheduler)
  │  └─ check_id = outcome.check_id (immutable per check)
  └─ [DECISION] Replace post_team_message() with post_watch_drift() RPC:
     └─ team.watch_drift.post(
        team_name, check_id, drift_kind, severity, finding
        ) to the Swift app
        (NOT via team.message.post "note" type anymore)

socket.rs
  └─ [DECISION] No new RPC handler in daemon socket
     (watch_drift posting is direct daemon→app, not through daemon RPC routing)
     (reduces coupling: watch_controller stays coupled only to Swift app, not to daemon routing)

                          Swift app
                          ─────────
TerminalController.swift
  ├─ Receive team.watch_drift.post RPC call from daemon
  └─ Dispatch to TeamDataStore.postWatchDrift()

TeamDataStore.swift
  ├─ New storage: watchDrifts[teamName: [WatchDriftItem]]
  │  └─ struct WatchDriftItem = { checkId, driftKind, severity, finding, timestamp }
  ├─ New method: postWatchDrift() — insert/upsert by check_id (idempotent)
  ├─ Updated: inboxItems() — include watch_drift items with priority 2
  └─ Effect: attentionCount automatically includes watch drift count

  Inbox item structure (in inboxItems() result):
  ┌─ kind: "watch_drift"
  ├─ priority: 2
  ├─ team_name: "standard"
  ├─ check_id: "a1b2c3d4" (dedup key)
  ├─ drift_kind: "execution" | "direction"
  ├─ severity: "high" | "medium" | "low"
  ├─ finding: "ignored a failing build"
  ├─ age_seconds: 45
  ├─ summary: "[watch:execution/high] ignored a failing build"
  └─ timestamp: ISO8601 string

StatusBar / Sidebar / AttentionBadge
  └─ attentionCount = number of inbox items (now includes watch_drift count)
     (already wired; no change needed)
```

---

## Implementation Stubs

### 1. Rust — `watch_controller.rs`

**Replace existing `post_team_message()` function:**

```rust
/// Post a watch drift finding to the leader inbox (focus-safe, data-only).
/// Returns Err if socket write fails; best-effort (failure doesn't block the outcome).
async fn post_watch_drift(
    app_socket: &str,
    team_id: &str,
    check_id: &str,
    drift_kind: &str,      // "execution" | "direction"
    severity: &str,        // "high" | "medium" | "low"
    finding: &str,         // human-readable finding text
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::UnixStream::connect(app_socket).await?;
    
    let req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "team.watch_drift.post",
        "params": {
            "team_name": team_id,
            "check_id": check_id,
            "drift_kind": drift_kind,
            "severity": severity,
            "finding": finding,
            // NO "from" field; watcher is anonymous via daemon
            // NO "type" field; kind is explicit in method
        },
    });
    
    let mut line = serde_json::to_string(&req).unwrap_or_default();
    line.push('\n');
    stream.write_all(line.as_bytes()).await?;
    stream.flush().await?;
    
    // Best-effort, bounded read of response (ignored, fire-and-forget).
    let mut buf = [0u8; 4096];
    let _ = tokio::time::timeout(std::time::Duration::from_secs(3), stream.read(&mut buf)).await;
    Ok(())
}

/// Update handle_outcome() to call post_watch_drift instead of post_team_message:
pub(crate) async fn handle_outcome<I: LeaderInbox + ?Sized>(
    outcome: &WatchCheckOutcome,
    working_dir: &Path,
    app_socket: Option<&str>,
    inbox: &I,
) -> ControllerAction {
    // ... parse_verdict, board append — no changes ...
    
    match append_board_finding(working_dir, &finding_row) {
        Ok(true) => {
            // NEW: post as watch_drift item instead of message
            if let Some(sock) = app_socket {
                if let Err(e) = post_watch_drift(
                    sock,
                    &outcome.team_id,
                    &outcome.check_id,
                    &drift_type,
                    &severity,
                    &finding,
                ).await {
                    tracing::warn!("watch: post_watch_drift failed (team {}): {e}", 
                                   outcome.team_id);
                }
            }
            ControllerAction::Appended
        }
        Ok(false) => ControllerAction::Duplicate,  // idempotent via check_id
        Err(e) => {
            tracing::warn!(
                "watch: board append failed (team {} check {}): {e}",
                outcome.team_id,
                outcome.check_id
            );
            ControllerAction::BoardError
        }
    }
}
```

---

### 2. Swift — `TerminalController.swift`

**Add dispatch case for `team.watch_drift.post`:**

```swift
case "team.watch_drift.post":
    return v2Result(id: id, self.teamDataWatchDriftPost(params: params))
```

**Add handler method:**

```swift
/// Data-only RPC: post a watch drift item to the leader inbox.
/// Focus-safe: no window.focus, send_key, or app activation (data mutation only).
private func teamDataWatchDriftPost(params: [String: Any], id: Any?, store: TeamDataStore) -> String {
    guard let teamName = params["team_name"] as? String else {
        return v2Error(id: id, code: "invalid_params", message: "Missing team_name")
    }
    guard let checkId = params["check_id"] as? String else {
        return v2Error(id: id, code: "invalid_params", message: "Missing check_id")
    }
    guard let driftKind = params["drift_kind"] as? String else {
        return v2Error(id: id, code: "invalid_params", message: "Missing drift_kind")
    }
    guard let severity = params["severity"] as? String else {
        return v2Error(id: id, code: "invalid_params", message: "Missing severity")
    }
    guard let finding = params["finding"] as? String else {
        return v2Error(id: id, code: "invalid_params", message: "Missing finding")
    }
    
    if store.postWatchDrift(
        teamName: teamName,
        checkId: checkId,
        driftKind: driftKind,
        severity: severity,
        finding: finding
    ) {
        return v2Ok(id: id, result: [
            "team_name": teamName,
            "check_id": checkId,
            "posted": true
        ])
    }
    return v2Error(id: id, code: "internal_error", message: "Failed to post watch drift")
}
```

---

### 3. Swift — `TeamDataStore.swift`

**Add storage struct:**

```swift
/// A watch drift finding in the leader inbox. Deduped by checkId; idempotent on post.
struct WatchDriftItem {
    let checkId: String          // Dedup key (deterministic from check)
    let driftKind: String        // "execution" | "direction"
    let severity: String         // "high" | "medium" | "low"
    let finding: String          // Human-readable finding text
    let timestamp: Date          // When posted (for age_seconds in inbox)
}
```

**Add storage dictionary (in class TeamDataStore):**

```swift
private var watchDrifts: [String: [WatchDriftItem]] = [:]  // teamName -> [items]
```

**Add method to post watch drift (idempotent upsert):**

```swift
/// Idempotently insert/upsert a watch drift item by checkId.
/// Returns true if successful, false if team not found or storage error.
func postWatchDrift(
    teamName: String,
    checkId: String,
    driftKind: String,
    severity: String,
    finding: String
) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    
    // Validate team exists
    guard teamRegistry[teamName] != nil else { return false }
    
    // Create item
    let item = WatchDriftItem(
        checkId: checkId,
        driftKind: driftKind,
        severity: severity,
        finding: finding,
        timestamp: Date()
    )
    
    // Idempotent upsert: remove old entry with same checkId, then append
    // (keeps latest timestamp on retry)
    watchDrifts[teamName, default: []].removeAll { $0.checkId == checkId }
    watchDrifts[teamName, default: []].append(item)
    
    return true
}
```

**Update `inboxItems()` method (add after existing task loop, before message loop):**

```swift
// Watch drift items (Phase 5)
for drift in watchDrifts[teamName, default: []] {
    let summary = "[watch:\(drift.driftKind)/\(drift.severity)] \(drift.finding.prefix(80))"
    items.append([
        "kind": "watch_drift",
        "priority": 2,                                    // High priority (below blocked tasks)
        "team_name": teamName,
        "check_id": drift.checkId,                        // Dedup key for idempotency
        "drift_kind": drift.driftKind,
        "severity": drift.severity,
        "finding": drift.finding,
        "age_seconds": Int(now.timeIntervalSince(drift.timestamp)),
        "summary": summary,
        "timestamp": ISO8601DateFormatter().string(from: drift.timestamp)
    ])
}
```

---

## Behavior

### Idempotency
- **Duplicate detection:** Two calls with the same `check_id` result in one inbox item.
- **Last-write-wins:** If retried, the newer call's timestamp overwrites the old one.
- **No double-notification:** Scheduler may retry a check; the same `check_id` ensures the leader sees it once.

### Threading & Focus Policy (CLAUDE.md Compliance)
- **Data-only:** `team.watch_drift.post` is pure Swift data mutation (dict insert). No window.focus, send_key, or app activation.
- **Main thread:** Handled via `v2MainSync` in TerminalController, conforming to socket threading policy.
- **No wakeup:** attentionCount is read on-demand (sidebar polling), so no explicit notification push needed.

### Integration with Existing Inbox
- **Existing kinds preserved:** "task" and "message" kinds remain unchanged.
- **Priority:** watch_drift items appear at priority 2 in the sorted inbox list.
- **Sidebar badge:** Automatically reflects total inbox count (no change needed to StatusBar or SidebarTabItem).

### Board.jsonl & Message Log
- **Board:** Drift findings still recorded in `.xm/watch/board.jsonl` (immutable audit trail) — unchanged.
- **Messages:** Optional — `post_team_message()` can be deprecated but isn't required for this change.
- **Separation:** Drifts live in inbox (ephemeral, actionable); messages stay in log (permanent, audit).

---

## Compatibility

### Backwards Compatibility
- **Old message.post path:** Can coexist during transition. Mark `post_team_message()` as `#[deprecated]` in `watch_controller.rs`.
- **Old UIs:** Clients polling `team.message.list` will no longer see drifts (they've moved to inbox). This is intentional — drifts elevate.
- **Fallback:** Older daemon versions can continue using `post_team_message()` until all watchers are updated.

### Phased Rollout
- **Phase 1 (now):** Add `watch.drift.post` RPC + inbox storage + integration.
- **Phase 2 (future):** Switch watch_controller to use `post_watch_drift()` instead of `post_team_message()`.
- **Phase 3 (optional):** Deprecate and remove `post_team_message()`.

---

## Test Cases

1. **Idempotency:** Post same check_id twice; verify inbox has one item with later timestamp.
2. **Priority ordering:** Post mixed task + message + drift items; verify drift appears at priority 2.
3. **Attention count:** Verify sidebar attentionCount badge increments when a drift is posted.
4. **Focus-safety:** Verify no window wakeup / app activation on drift post (verify no DispatchQueue.main.async in handler).
5. **Inbox retrieval:** `team.inbox` RPC returns watch_drift items with correct structure.
6. **Dedup across retries:** Scheduler retries a check (same check_id); leader inbox shows one item.

---

## Files to Modify

| File | Section | Lines | Change Type |
|------|---------|-------|-------------|
| `watch_controller.rs` | `post_watch_drift()` function | ~250–300 | Replace existing `post_team_message()` |
| `watch_controller.rs` | `handle_outcome()` | ~335–365 | Call new `post_watch_drift()` instead |
| `TerminalController.swift` | dispatch case | ~1920 | Add `"team.watch_drift.post"` case |
| `TerminalController.swift` | `teamDataWatchDriftPost()` method | ~3470 | New handler function |
| `TeamDataStore.swift` | `WatchDriftItem` struct | ~50 | New struct definition |
| `TeamDataStore.swift` | `watchDrifts` dict | ~150 | Add storage property |
| `TeamDataStore.swift` | `postWatchDrift()` method | ~200 | New method |
| `TeamDataStore.swift` | `inboxItems()` method | ~890 | Add watch drift loop |

---

## Summary

### What Changes
- Watch drift findings now appear in leader inbox with `kind: "watch_drift"` and priority 2.
- Sidebar attention badge automatically reflects the number of unresolved drifts (already wired via attentionCount).
- Idempotency via `check_id` prevents duplicate inbox entries on scheduler retries.

### What Stays the Same
- Board.jsonl recording remains unchanged (immutable audit trail).
- Message log remains unchanged (backwards compat).
- Socket threading and focus policies remain compliant (data-only RPC).
- Existing task and message kinds unaffected.

### Minimal Surface
- 3 new Swift functions/structures + 1 Rust function + 2 method extensions.
- No refactoring of existing message/task logic.
- ~400 lines of code (Rust: 50–80, Swift: 350–400).

---

## Design Rationale Summary

| Aspect | Decision | Why |
|--------|----------|-----|
| Separate kind | `"watch_drift"` vs message type | Metadata + idempotency needs differ from messages |
| Priority | 2 (high, not highest) | Actionable but not runner-blocking |
| Dedup key | check_id | Deterministic, stable across retries, already in payload |
| RPC path | Direct daemon→app, no daemon routing | Reduces coupling; watcher-specific concern stays at boundary |
| Storage | Separate watchDrifts dict | Enables future acknowledge/clear semantics |
| Focus-safe | Data-only, no window.focus | Complies with CLAUDE.md socket threading policy |

