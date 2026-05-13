# Phase 2 — Headless Agent Resume: RPC Contract & Disk Schema

Status: contract (no code). Target consumers: backend (term-meshd), frontend (Sources/TeamOrchestrator.swift, TeamCreationView.swift, TeamDataStore.swift).

This document fixes the on-disk metadata layout, JSON-RPC method shapes, CLI argument flow, state-machine deltas, and UI binding for the Phase 2 *Resume from previous team* feature. Implementation should follow these definitions byte-for-byte; deviations require a contract bump.

All schemas carry a top-level `"schema": 1` integer. Future migrations bump that field; readers MUST reject unknown major versions.

---

## 1. Disk Metadata Schema

### 1.1 Root layout

```
~/.term-mesh/headless/
  <team_uuid>/                      # live team
    team.json
    agents/
      <agent_name>.json
    instructions/
      <agent_name>.txt              # raw bytes — no transformation
  <team_uuid>.archived.<unix_ts>/   # destroyed team (GC after 7 days)
    team.json                       # destroyed_at set, schema unchanged
    agents/<agent_name>.json
    instructions/<agent_name>.txt
```

- `<team_uuid>` is a lowercase UUIDv4 (36 chars with dashes). It is the **stable** identity used by `--session-id`/`--resume` for the *leader*; individual agents have their own session UUIDs (see `agents/<name>.json`).
- `<unix_ts>` in archived names is the seconds-since-epoch value of `destroyed_at`. Used purely for filesystem-level deduplication when a team is destroyed, recreated under the same UUID, and destroyed again (theoretical — UUIDs are fresh per `create_team`, but the suffix guarantees no collision).
- File permissions: directories `0700`, files `0600`. Daemon writes only.
- Atomic writes: write to `*.tmp` in the same directory, `fsync`, then `rename(2)`. Readers MUST tolerate a missing `*.tmp`.

### 1.2 `team.json`

```jsonc
{
  "schema": 1,                                       // integer, required
  "team_uuid": "8f3d1a2b-4c5e-4f6a-9b8c-0d1e2f3a4b5c", // string, required, matches dir name
  "team_name": "my-team",                            // string, required, user-visible
  "created_at": 1715600000,                          // u64 unix seconds, required
  "destroyed_at": null,                              // u64|null — null while live, set on destroy
  "working_directory": "/Users/j/proj",              // string, required, absolute path (realpath at create time)
  "git_root": "/Users/j/proj",                       // string|null — realpath of git toplevel containing working_directory; null if not a git repo
  "git_branch_at_create": "feat/agent-view",         // string|null — branch resolved at create time
  "leader": {                                        // required object
    "mode": "claude",                                // "repl"|"claude"|"kiro"|"codex"|"gemini"|"adopted"
    "model": "sonnet",                               // string, free-form
    "session_id": "8f3d1a2b-4c5e-4f6a-9b8c-0d1e2f3a4b5c"  // string|null — only set when mode == "claude"
  },
  "agents": ["explorer", "executor", "reviewer"],    // array<string>, ordered as displayed
  "worktree": {                                      // object|null — null when worktree_mode == "off"
    "mode": "isolated",                              // "shared"|"isolated"
    "path": "/Users/j/.gk/worktree/proj/team-x",     // string, absolute, realpath
    "branch": "team/my-team"                         // string
  },
  "execution_mode": "headless",                      // always "headless" for Phase 2 entries
  "claude_cli_version": "1.2.3",                     // string|null — `claude --version` captured at create; null if unavailable
  "termmesh_app_version": "0.113.0",                 // string, required
  "app_socket_path_at_create": "/tmp/term-mesh.sock", // string|null — for diagnostics only, not used at resume
  "runbook_digest_hash": "sha256:ab12…cd34"          // string|null — hash of the digest mode source used by AgentRunbookService at create
}
```

Field rules:

- `team_uuid` MUST equal the parent directory's UUID component. Mismatch ⇒ skip with log.
- `destroyed_at` is the ONLY field rewritten after creation under live-team rules. On destroy, the daemon rewrites `team.json` once with `destroyed_at` set, then renames the directory. (Single mutation point keeps logic auditable.)
- `runbook_digest_hash` lets `list_resumable` flag `runbook_matches` without re-reading instructions.

### 1.3 `agents/<agent_name>.json`

```jsonc
{
  "schema": 1,
  "team_uuid": "8f3d1a2b-...",                       // back-reference for orphan detection
  "name": "explorer",                                // matches filename stem
  "agent_type": "explorer",                          // role name (may equal name)
  "cli": "claude",                                   // "claude"|"kiro"|"codex"|"gemini"
  "model": "sonnet",                                 // string
  "session_id": "1a2b3c4d-...",                      // string|null — UUIDv4. null when cli != "claude" (only claude supports resume in Phase 2)
  "color": "green",
  "created_at": 1715600000,                          // u64 unix seconds
  "instructions_sha256": "9f2e…",                    // hex SHA-256 of instructions/<name>.txt bytes; null if no instructions
  "cli_path_at_create": "/opt/homebrew/bin/claude",  // string|null — for diagnostics
  "parked": false                                    // bool, default false (Phase 2 idle-park; see §5)
}
```

- `session_id` MUST be a fresh UUIDv4 generated by the daemon at create time and passed to the CLI via `--session-id`. The daemon never reads back the `system/init` `session_id` to derive identity — it is the authority.
- `instructions_sha256` is the SHA-256 of the **raw bytes** of the instructions file. If empty, the file is absent and this field is `null`.

### 1.4 `instructions/<agent_name>.txt`

- **Raw bytes**, no BOM, no trailing-newline normalization, no encoding conversion.
- Whatever `AgentRunbookService.composeInstructions(...)` returned at create time is written verbatim. Swift's `String.utf8` view → `Data` → file. Rust reads with `std::fs::read(...)` → `Vec<u8>` and passes through to `Command::arg` as `OsStr::from_bytes` (Unix).
- Empty instructions ⇒ no file. The `--append-system-prompt` flag is omitted in that case.
- Filename: `<agent_name>.txt` where `<agent_name>` is the literal name. Names containing `/`, NUL, or starting with `.` are rejected at create time (validation MUST happen before any file write).

### 1.5 Archived naming

On destroy:

1. Daemon updates `team.json` with `destroyed_at = <now>`.
2. Daemon renames `<team_uuid>/` → `<team_uuid>.archived.<destroyed_at>/`.
3. GC sweep removes any `*.archived.*` directory whose suffix is ≥ 7 days old.

GC schedule: on daemon startup (after socket bind) and every 12 hours via `tokio::time::interval`. Failure to delete (permission, in-use) is logged but does not retry until the next interval.

---

## 2. New RPC Methods

All methods follow the existing JSON-RPC envelope used by `socket.rs` (request: `{method, params}`, response: `{result}` or `{error: "<msg>"}`).

### 2.1 `headless.list_resumable`

Returns resumable-team candidates by scanning archived directories.

**Params**

```jsonc
{
  "git_root": "/Users/j/proj",   // string|null|absent — when present, filters to teams whose team.json git_root realpath-equals this value
  "limit": 50                     // int, default 50, max 200
}
```

**Result**

```jsonc
{
  "teams": [
    {
      "team_uuid": "8f3d1a2b-...",
      "team_name": "my-team",
      "created_at": 1715500000,
      "destroyed_at": 1715600000,
      "working_directory": "/Users/j/proj",
      "git_root": "/Users/j/proj",
      "git_branch_at_create": "feat/agent-view",
      "git_branch_now": "main",                  // string|null — current branch at the working_directory if it exists and is a repo
      "worktree": {
        "mode": "isolated",
        "path": "/Users/j/.gk/worktree/proj/team-x",
        "branch": "team/my-team",
        "exists": true,                          // bool — does the directory still exist?
        "branch_now": "team/my-team"             // string|null — current branch in that worktree, null if missing
      },                                          // object|null — null if team had no worktree
      "agents": [
        {
          "name": "explorer",
          "agent_type": "explorer",
          "cli": "claude",
          "model": "sonnet",
          "color": "green",
          "has_session": true,                   // session_id != null
          "has_instructions": true
        }
        // …
      ],
      "validity": {
        "worktree_exists":     true,             // false if team had a worktree and it's now gone
        "branch_matches":      true,             // git_branch_at_create == git_branch_now (or worktree branch_now)
        "runbook_matches":     true,             // current digest hash == runbook_digest_hash
        "cli_version_matches": true,             // current `claude --version` == claude_cli_version (string equality)
        "all_sessions_present": true             // every claude agent has a non-null session_id
      },
      "resumable": true,                         // = worktree_exists && all_sessions_present
      "blocking_reason": null                    // string|null — "worktree_gone"|"no_sessions"|"corrupt"|null
    }
  ],
  "scanned": 17,                                 // int — total directories examined
  "skipped": 1                                   // int — corrupt or unreadable
}
```

Sorting: `destroyed_at` descending, then `team_name` ascending as tie-break.

Corrupt rows (JSON parse fail, schema mismatch, UUID mismatch) are excluded from `teams[]` and counted in `skipped`. The daemon MUST log each skip at `warn` level with the path.

Errors: returns `"error": "<reason>"` only on catastrophic failure (cannot read `~/.term-mesh/headless`). Empty/missing directory ⇒ `teams: []`.

### 2.2 `headless.resume_team`

Resumes a destroyed team by re-spawning all agents with `--resume <session_id>` and the original instructions.

**Params**

```jsonc
{
  "team_uuid": "8f3d1a2b-...",            // string, required
  "team_name_override": null,             // string|null — if set, use this as live team_name; defaults to archived team_name
  "leader_session_id": "abc-...",         // string, required — Swift-supplied leader session UUID (same role as create_team's field)
  "app_socket_path": "/tmp/term-mesh.sock", // string|null
  "accept_branch_drift": false            // bool, default false — when false and branch_matches==false, request is rejected
}
```

**Result** — identical shape to `headless.create_team`'s result (`HeadlessTeam` serialization) plus a `resumed: true` marker:

```jsonc
{
  "name": "my-team",
  "agents": ["explorer@my-team", "executor@my-team", "reviewer@my-team"],
  "working_directory": "/Users/j/proj",
  "leader_session_id": "abc-...",
  "created_at": 1715700000,
  "team_uuid": "8f3d1a2b-...",            // NEW field — also added to live HeadlessTeam (see §3)
  "resumed": true
}
```

**Errors** (string `error` field):

| code (substring match) | meaning |
|---|---|
| `team_not_found` | no archived (or live) directory with that uuid |
| `team_already_live` | a live team with this `team_uuid` exists |
| `team_name_in_use` | resolved `team_name` is already used by a different live team |
| `worktree_gone` | `worktree.path` does not exist on disk |
| `branch_drift_rejected` | `accept_branch_drift=false` and branches differ |
| `no_sessions` | no agent has a session_id (e.g., migrated old team) |
| `cli_spawn_failed: <agent>: <reason>` | one agent failed to spawn; full rollback performed |
| `corrupt_metadata: <field>` | JSON malformed or schema mismatch |

On any error, no partial state is left: any agent spawned during the attempt is terminated, and the archived directory is NOT renamed back to live.

On success:

1. Daemon renames `<uuid>.archived.<ts>/` → `<uuid>/`.
2. Daemon rewrites `team.json` with `destroyed_at = null` (single atomic write).
3. Each agent's `cli_path_at_create` is **not** updated; resume reuses captured values when the binary still exists, falling back to env lookup if not.

### 2.3 `headless.create_team` — Modified (see §3 for details on signature)

Existing call extended to:

- Accept optional `session_ids: { "<agent_name>": "<uuid>" }` map. When omitted, the daemon generates fresh UUIDv4 per claude agent. When present, daemon uses provided values (resume path). Non-claude agents ignore this map.
- Accept optional `team_uuid: "<uuid>"`. Omitted ⇒ fresh UUIDv4. Provided ⇒ use as-is (resume path). MUST validate UUID format; reject malformed.
- Always return `team_uuid` in the result.

**Recommendation:** keep `create_team` as the single spawn entry point; `resume_team` is a thin wrapper that (a) reads metadata, (b) builds `TeamCreateParams` with `session_ids` and `team_uuid` populated, (c) calls the same `create_team` internal path, (d) on success performs the rename + `destroyed_at` rewrite.

**Rationale:** spawn logic is identical aside from the CLI flag and session-id source; duplicating it across two RPC handlers risks divergence (e.g., env var changes, stderr piping rules). The cost is a small `if session_ids.contains_key(name) { --resume } else { --session-id }` branch in `cli_builder::build_claude_command`.

**Alt:** separate `respawn_agent` internal API. Rejected because rollback semantics are easier to reason about when one function owns the whole transaction.

### 2.4 `headless.set_idle_park_minutes`

Configures the global idle-park threshold.

**Params**

```jsonc
{ "minutes": 30 }   // int, 0 ≤ minutes ≤ 1440. 0 disables auto-park.
```

**Result**

```jsonc
{ "minutes": 30, "active": true }
```

Persistence: stored in `~/.term-mesh/headless/config.json` (`{"schema":1, "idle_park_minutes": 30}`). Read on daemon startup; defaults to `0` (disabled) until set.

### 2.5 `headless.park_agent`

Immediately parks one agent. Equivalent to terminating its subprocess while keeping all metadata on disk (live, not archived).

**Params**

```jsonc
{ "team_name": "my-team", "agent_name": "explorer" }
```

**Result**

```jsonc
{ "parked": true, "agent_name": "explorer", "session_id": "1a2b..." }
```

**Errors**: `team_not_found`, `agent_not_found`, `agent_already_parked`, `agent_terminated` (subprocess died without parking).

Side effect: writes `parked: true` into `agents/<name>.json`. The live team directory and `team.json` remain unchanged (the team is still considered live; `destroyed_at == null`).

### 2.6 `headless.unpark_agent`

Re-spawns a parked agent using its stored `session_id` and instructions.

**Params**

```jsonc
{ "team_name": "my-team", "agent_name": "explorer", "app_socket_path": "/tmp/term-mesh.sock" }
```

**Result**: `AgentInfo` (identical shape to current `headless.spawn`'s result), plus `unparked: true`.

**Errors**: `team_not_found`, `agent_not_found`, `agent_not_parked`, `cli_spawn_failed: <reason>`, `no_session` (claude only; if `session_id == null` the agent cannot be unparked — return error rather than silently re-creating a session).

---

## 3. Existing RPC Changes

### 3.1 `headless.create_team`

**Params (extended)**

```jsonc
{
  "team_name": "my-team",
  "working_directory": "/Users/j/proj",
  "leader_session_id": "abc-...",
  "agents": [
    { "name": "explorer", "agent_type": "explorer", "cli": "claude", "model": "sonnet",
      "cli_path": "/opt/homebrew/bin/claude", "instructions": "...", "color": "green" }
  ],
  "app_socket_path": "/tmp/term-mesh.sock",

  // NEW (all optional):
  "team_uuid": "8f3d1a2b-...",              // string|null — caller-supplied; daemon generates if absent
  "session_ids": {                           // object|null — per-agent session UUIDs (resume path only)
    "explorer": "1a2b3c4d-..."
  },
  "worktree": {                              // object|null — record-only (does not affect spawn); used for metadata
    "mode": "isolated",
    "path": "/Users/j/.gk/worktree/proj/team-x",
    "branch": "team/my-team"
  },
  "git_root": "/Users/j/proj",               // string|null — realpath; used for list_resumable filtering
  "git_branch_at_create": "feat/agent-view", // string|null
  "claude_cli_version": "1.2.3",             // string|null — Swift captures via `claude --version`; daemon stores verbatim
  "termmesh_app_version": "0.113.0",         // string, required
  "runbook_digest_hash": "sha256:ab12...",   // string|null
  "agent_type": "..."                         // (in each AgentSpec) — already supplied by Swift code; now persisted
}
```

`AgentSpec` extension: `agent_type: String` (required for new code; daemon defaults to `spec.name` if absent for back-compat with v0 callers).

**Result (extended)**

```jsonc
{
  "name": "my-team",
  "team_uuid": "8f3d1a2b-...",   // NEW — always present
  "agents": ["explorer@my-team", ...],
  "working_directory": "/Users/j/proj",
  "leader_session_id": "abc-...",
  "created_at": 1715700000
}
```

The daemon's `HeadlessTeam` struct gains a `team_uuid: String` field. Existing callers reading the result by field name are unaffected (additive change).

### 3.2 `headless.destroy_team`

Behavior change (params unchanged: `{ "team_name": "..." }`):

1. Resolve `team_uuid` by `team_name` (in-memory team map).
2. Terminate all agent subprocesses (existing logic).
3. Rewrite `team.json` with `destroyed_at = <now>` (single atomic write).
4. Rename `<team_uuid>/` → `<team_uuid>.archived.<destroyed_at>/`.
5. Remove in-memory team + agent entries.
6. Return `{"status":"ok", "team_uuid": "...", "archived_path": "/Users/.../<uuid>.archived.<ts>"}`.

Errors: `team_not_found`. Filesystem failures during rename/rewrite are logged but do NOT block the in-memory cleanup — disk state diverging from memory is preferable to a half-destroyed team being unrecoverable. The next GC sweep is responsible for noticing orphans (best-effort).

### 3.3 GC sweep (internal, not RPC)

Triggered on:
- Daemon startup (after socket bind, before accepting connections is fine — non-blocking).
- Every 12 hours.

Action: for each `<uuid>.archived.<ts>/`, if `now - ts >= 604800` (7 days), `fs::remove_dir_all`. Log count of removed directories.

Live directories (`<uuid>/` with no `.archived.<ts>` suffix) are never touched by GC.

---

## 4. CLI Argument Construction

`build_claude_command` signature gains a `SpawnMode` parameter:

```text
enum SpawnMode {
    Fresh { session_id: String },        // new session
    Resume { session_id: String },       // resuming existing session
}
```

(Or an `Option<String>` "resume_session_id" with `None` ⇒ Fresh — equivalent, pick whichever is more idiomatic in Rust.)

### 4.1 Fresh spawn argv

```
claude
  --session-id <uuid>
  --print
  --input-format stream-json
  --output-format stream-json
  --verbose
  --dangerously-skip-permissions
  --model <model>
  [--append-system-prompt <raw-bytes>]
```

### 4.2 Resume argv

```
claude
  --resume <uuid>
  --print
  --input-format stream-json
  --output-format stream-json
  --verbose
  --dangerously-skip-permissions
  --model <model>
  [--append-system-prompt <raw-bytes>]
```

### 4.3 Mandatory rules

- `--print` is added unconditionally. Rationale: the current implementation relies on Anthropic CLI auto-detecting non-TTY stdout to enter print mode. A future CLI release could change that default; `--print` makes intent explicit and is a no-op when already implicit. The cost is one CLI flag.
- `--append-system-prompt` value MUST be the raw bytes of `instructions/<agent_name>.txt`, passed as `OsStr` (Unix: `OsStrExt::from_bytes(&vec_u8)`). **NO** quote escaping, **NO** `replace('\'', "'\\''")`, **NO** UTF-8 round-trip. The current `cli_builder.rs` line 85 (`let escaped = inst.replace('\'', "'\\''");`) MUST be removed — `Command::arg` does not pass through a shell, so the escape is actively wrong and currently causes silent bytewise drift in instructions containing single quotes. (This is a bugfix in addition to a Phase 2 requirement.)
- Empty/missing instructions ⇒ omit both `--append-system-prompt` and its argument. NEVER pass an empty string (some CLI versions interpret that differently from "absent").
- The `--append-system-prompt` value on resume MUST be byte-identical to the value used at create time. Daemon verifies this implicitly by reading the same `instructions/<name>.txt` file. If `instructions_sha256` in `agents/<name>.json` does not match the actual file hash at resume time, return `corrupt_metadata: instructions_hash`.
- Argument order is fixed as above for diff/audit stability across daemon versions. Tests SHOULD assert exact argv equality.

### 4.4 Non-claude CLIs

Phase 2 does NOT extend resume to kiro/codex/gemini. Their `cli_builder` functions are untouched. Their `agents/<name>.json` records carry `session_id: null` and are excluded from resume eligibility (`all_sessions_present` becomes false if a team mixes claude and non-claude agents).

---

## 5. `agent_state` Enum Extension

Add `parked` to the enum referenced in `Sources/TeamDataStore.swift` lines 493–504 and `Sources/SidebarTabItem.swift` lines 886–900.

### 5.1 State values

| state | dot color | meaning |
|---|---|---|
| `idle` | gray (`.gray`) | no active task, subprocess running |
| `running` | green | active non-terminal task |
| `blocked` | red | task status `blocked` |
| `review_ready` | yellow | task status `review_ready` |
| `error` | red @ 0.7 opacity | task status `failed` |
| `parked` | gray with pause glyph (`⏸`, or `Color.gray.opacity(0.5)` if glyph rendering is restricted) | subprocess terminated, metadata preserved |

### 5.2 Transitions

| from → to | trigger |
|---|---|
| `idle` → `parked` | idle timer expiry OR `headless.park_agent` RPC |
| `running` → `parked` | **forbidden**; daemon rejects `park_agent` when an active non-terminal task exists. UI MUST disable manual park while running. |
| `parked` → `running` | `headless.unpark_agent` RPC. Restoring an unparked agent with a queued message immediately puts it in `running`. |
| `parked` → `idle` | unpark with no pending task |
| `parked` → terminal states (`blocked`/`error`/`review_ready`) | not directly; must first transition through `running` |
| any → `terminated` (= team destroyed) | `destroy_team` RPC |

The "idle timer" is per-agent. Reset criteria: any stdin write to the agent OR any non-empty stdout line received. When `(now - last_activity) >= idle_park_minutes * 60` and `agent_state == idle`, daemon auto-parks (silent — emits an event but no user prompt).

### 5.3 `TeamDataStore.swift:493` mapping

Add this branch in the `if let task = activeTask` block (priority: explicit parked flag overrides task-derived state, because a parked agent has no live subprocess regardless of its task board entry):

```text
// Pseudo (NOT code):
//   if let agentInfo = headlessAgentInfo[teamName][agentName], agentInfo.parked {
//       agentState = "parked"
//   } else if let task = activeTask { … existing switch … } else { agentState = "idle" }
```

`headlessAgentInfo` is the existing daemon-mirrored agent map already used for `agentDataEnrichment`; the `parked` bool is added to its serialization (from `agents/<name>.json` or in-memory state).

---

## 6. UI (TeamCreationView)

### 6.1 Mode selector

Above the existing form, insert a radio group:

```
( ) New session                  ← default
( ) Resume from previous team
```

State variable: `@State private var creationMode: String = "new"`. Switching to "resume" hides the agent-config rows and reveals the candidate list. Switching back restores the new-session form.

### 6.2 Candidate list

Populated by `headless.list_resumable` (params `git_root = current cwd's git root`, `limit = 50`). Daemon-side filter; client passes through.

Filter toggle, top-right of the list area:

```
[ This repo ] [ All ]     // mutually exclusive segmented control
```

"This repo" calls `list_resumable` with `git_root` populated from the workspace's current `gitRepoRoot` (already tracked in `Team` / `TeamOrchestrator`). "All" calls it without `git_root`. Default: "This repo".

### 6.3 Row structure

Each row, top to bottom:

```
┌──────────────────────────────────────────────────────────────────┐
│  my-team                                          3 agents       │  ← team_name + agent count
│  destroyed 2h ago  •  /Users/j/proj                              │  ← relative destroyed_at + working_directory
│  worktree: team/my-team @ /…/proj/team-x      ⚠ branch was       │  ← worktree.path + branch_matches indicator
│                                                  feat/x → main   │
│  ▸ explorer  (claude, sonnet, green) ✓                           │  ← collapsible per-agent
│  ▸ executor  (claude, sonnet, blue)  ✓                           │
│  ▸ reviewer  (claude, sonnet, yellow) ✓                          │
└──────────────────────────────────────────────────────────────────┘
```

- Branch indicator: `✓` when `branch_matches`, `⚠ branch was <X> → now <Y>` when not.
- Per-agent checkmark: `✓` when `has_session && has_instructions`, `✗` otherwise (and disabled tooltip explains).
- Relative time uses existing `RelativeDateTimeFormatter` patterns elsewhere in Sources/.

### 6.4 Row disabled / enabled rules

| validity field | failed ⇒ row state |
|---|---|
| `worktree_exists == false` | row disabled, hover: "Worktree directory no longer exists: <path>" |
| `all_sessions_present == false` | row disabled, hover: "Cannot resume — agents have no session IDs (created before Phase 2)" |
| `branch_matches == false` | row enabled, ⚠ shown; on click, confirm dialog: "Branch has changed since this team was created (was <X>, now <Y>). Resume anyway on the current branch?" → if confirmed, call `resume_team` with `accept_branch_drift = true` |
| `runbook_matches == false` | row enabled, hover note: "Runbook has changed since creation. Resume will use the original instructions (cache hit), but agent behavior may differ from a fresh team." — no confirm dialog |
| `cli_version_matches == false` | row enabled, hover note: "Claude CLI version differs (was <X>, now <Y>). Resume may fail; if so, the team will report an error." |

### 6.5 Action button

Selecting a row enables the existing primary button, relabeled `Resume Team` (replacing `Create Headless Team`). Click invokes `headless.resume_team` with the selected `team_uuid`. On success, `TeamOrchestrator` constructs the same `Team` model as create (with `executionMode = "headless"`) using the result.

### 6.6 No new-session fields shown in resume mode

The existing agent picker, worktree mode picker, execution mode picker, and resume-leader-session toggle are all hidden while `creationMode == "resume"`. The resumed team's worktree mode, execution mode, and agent set are determined entirely by stored metadata.

---

## 7. Safety / Edge Cases

| scenario | behavior |
|---|---|
| `team.json` JSON parse error or schema mismatch | Skip the directory in `list_resumable`, increment `skipped`, log at `warn` with the path. Do NOT auto-delete. |
| `agents/<name>.json` missing for a name listed in `team.json:agents[]` | Treat team as corrupt: exclude from `list_resumable`, log. `resume_team` returns `corrupt_metadata: agents/<name>.json`. |
| `instructions/<name>.txt` missing but `instructions_sha256 != null` | `corrupt_metadata: instructions_hash`. (Do NOT fall back to empty.) |
| `instructions/<name>.txt` SHA mismatch | `corrupt_metadata: instructions_hash`. |
| `session_id` rejected by `claude --resume` (CLI exits non-zero or `system/init` is missing) | Resume aborts: terminate any already-spawned siblings, return `cli_spawn_failed: <agent>: session_rejected`. **Do NOT** silently fall back to a fresh `--session-id`. Rationale: a silent fallback breaks the user's mental model (they asked for resume, not a new team) and silently discards their previous context. The error includes the CLI's stderr first line to aid debugging. |
| User tries to resume a `team_uuid` whose live counterpart already exists in memory | `team_already_live` error. (Defense: also covers the race where two RPC calls arrive in parallel — `create_team` already serializes on `HeadlessManager`'s `Mutex`.) |
| User tries to resume a team whose `team_name` collides with a different live team | `team_name_in_use`. UI can offer a rename: pass `team_name_override` in the next call. |
| Resume attempted twice for the same `team_uuid` in quick succession | Second call sees the rename-to-live already happened ⇒ `team_already_live`. The first call wins. |
| Archived metadata copied from another machine via git/dropbox | `claude_cli_version_matches` and `cli_path_at_create` will likely fail. `cli_version_matches` shows ⚠ in UI; resume still attempted. **However**, `git_root` and `working_directory` paths are absolute and may not exist on the new machine ⇒ `worktree_exists` will be false ⇒ row disabled. **This is intentional**: cross-machine resume is out of scope for Phase 2. Document this in CHANGELOG. |
| `worktree.path` points through a symlink to a different target than at create time | `worktree.exists` uses `std::fs::canonicalize` (realpath). If realpath differs from the stored `worktree.path` (which was already canonicalized at create), treat the worktree as gone. Rationale: the symlinked-elsewhere case usually means the user moved/recreated the worktree under the same name; their context is no longer valid. |
| Daemon crashes mid-destroy (rewrite done, rename not yet) | Next GC sweep / startup scan finds a live directory with `destroyed_at != null`. Treat as destroyed: complete the rename. (Implement a "fixup" pass at startup before GC.) |
| Daemon crashes mid-resume (renamed to live, agents not spawned, no `destroyed_at = null` rewrite yet) | On startup, daemon scans live directories. If `team.json:destroyed_at != null` AND no in-memory team exists, treat the team as destroyed: leave directory in place but the GC fixup will re-rename it back to archived on the next sweep, OR (preferred) re-rename it immediately on startup. Pick the latter; it's a single rename + zero loss of resumability. |
| Idle-park config (`headless.set_idle_park_minutes`) changed while agents are running | New value takes effect on next idle-state evaluation tick; in-flight timers are not reset. |

---

## 8. Migration

Existing live teams created before Phase 2:

- Have no `~/.term-mesh/headless/<uuid>/` directory (the directory is created by Phase 2 `create_team`).
- Will continue to operate identically (in-memory team registry is unchanged).
- On `destroy_team`, the daemon detects "no metadata dir for this team" and emits a minimal archived stub:

  ```jsonc
  {
    "schema": 1,
    "team_uuid": "<generated-now>",
    "team_name": "<original>",
    "created_at": <stored created_at>,
    "destroyed_at": <now>,
    "working_directory": "<stored>",
    "git_root": null,
    "leader": { "mode": "<stored>", "model": "<stored>", "session_id": null },
    "agents": [<names>],
    "worktree": null,
    "execution_mode": "headless",
    "claude_cli_version": null,
    "termmesh_app_version": "<current>",
    "runbook_digest_hash": null
  }
  ```

  And per-agent stubs with `session_id: null, instructions_sha256: null`. No `instructions/<name>.txt` files are written (we don't have the original bytes).

- These stubs appear in `list_resumable` with `all_sessions_present: false` ⇒ `resumable: false` ⇒ row visible but disabled, hover: "Created before Phase 2 — cannot resume."

- They are GC'd normally after 7 days.

No migration of in-memory state is needed. Existing teams MUST NOT be retroactively assigned UUIDs or written to disk while alive — only on destroy.

---

## 9. Open items deliberately fixed by this contract

- **UUID source of truth**: daemon-generated, never CLI-derived.
- **Instructions encoding**: raw bytes, no escape, no shell.
- **Resume granularity**: team-level only. No per-agent resume RPC in Phase 2.
- **Cross-machine**: out of scope, gated by absolute-path liveness.
- **Non-claude CLIs**: out of scope for resume; metadata recorded for future Phase 3.
- **Idle park is "silent"**: no toast / no notification on auto-park. UI dot color change is the only signal. A future Phase may add an event stream subscription.
