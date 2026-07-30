//! Phase 2 — Headless team metadata on disk.
//!
//! Layout:
//! ```text
//! ~/.term-mesh/headless/
//!   config.json
//!   <team_uuid>/                       # live
//!     team.json
//!     agents/<agent_name>.json
//!     instructions/<agent_name>.txt    # raw bytes
//!   <team_uuid>.archived.<unix_ts>/    # archived (GC after 7d)
//! ```
//!
//! All writes are atomic (`*.tmp` + `fsync` + `rename`). All filesystem I/O lives
//! off the main socket-handler thread (callers are already inside `tokio::spawn`
//! or short-lived `tokio::task::spawn_blocking` style flows). See CLAUDE.md
//! "Socket command threading policy".

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const SCHEMA_VERSION: u32 = 2;
/// Oldest schema this daemon still reads. v1 files (pre live-snapshot) parse
/// cleanly because every v2 field defaults via serde.
pub const MIN_SCHEMA_VERSION: u32 = 1;
pub const ARCHIVE_RETENTION_SECS: u64 = 7 * 24 * 60 * 60; // 7 days
pub const GC_INTERVAL_SECS: u64 = 12 * 60 * 60; // 12 hours

/// Phase 2 schema version of `team.json` (top-level `schema` field).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TeamMeta {
    pub schema: u32,
    pub team_uuid: String,
    pub team_name: String,
    pub created_at: u64,
    pub destroyed_at: Option<u64>,
    pub working_directory: String,
    pub git_root: Option<String>,
    pub git_branch_at_create: Option<String>,
    pub leader: LeaderMeta,
    pub agents: Vec<String>,
    pub worktree: Option<WorktreeMeta>,
    pub execution_mode: String,
    pub claude_cli_version: Option<String>,
    pub termmesh_app_version: String,
    pub app_socket_path_at_create: Option<String>,
    pub runbook_digest_hash: Option<String>,
    /// Schema v2 — live-snapshot support (Restore Fleet Layer 1).
    /// `true` while the team is (believed to be) running: the dir under
    /// `<team_uuid>/` is a continuously-refreshed snapshot, not an archive.
    /// Set back to `false` (and the dir renamed to `.archived.<ts>`) on
    /// destroy. v1 files default to `false`, which preserves their meaning.
    #[serde(default)]
    pub live: bool,
    /// Unix-seconds of the most recent live snapshot write. None on v1 files
    /// and on archives written by the destroy path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_snapshot_at: Option<u64>,
    /// Title of the team's workspace tab at snapshot time, reused verbatim
    /// when the fleet is restored.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout_workspace_title: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LeaderMeta {
    pub mode: String,
    pub model: String,
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorktreeMeta {
    pub mode: String,
    pub path: String,
    pub branch: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentMeta {
    pub schema: u32,
    pub team_uuid: String,
    pub name: String,
    /// Durable, team-scoped identity. Absent only in legacy metadata and
    /// migrated on the next persistence/resume write.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_instance_id: Option<String>,
    pub agent_type: String,
    pub cli: String,
    pub model: String,
    pub session_id: Option<String>,
    pub color: Option<String>,
    pub created_at: u64,
    pub instructions_sha256: Option<String>,
    pub cli_path_at_create: Option<String>,
    #[serde(default)]
    pub parked: bool,
    /// Phase 2.5: cumulative token usage across the agent's lifetime.
    /// Optional and back-compatible — absent/null is treated as zero counts.
    /// Survives park/unpark and destroy/resume cycles.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_total: Option<UsageTotals>,
    /// CLI profile: extra arguments appended after the standard args.
    /// Persisted so park→unpark and destroy→resume preserve the profile.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extra_args: Vec<String>,
    /// CLI profile: extra environment variables merged into the subprocess env.
    /// Persisted so park→unpark and destroy→resume preserve the profile.
    #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
    pub extra_env: std::collections::HashMap<String, String>,
    /// Auto-recycle threshold: recycle this agent every N completed tasks.
    /// None = disabled; 0 = explicitly disabled.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_recycle_every: Option<u32>,
    /// Running count of tasks completed by this agent (reset on recycle).
    #[serde(default)]
    pub completed_task_count: u32,
    /// Schema v2 — unix-seconds when the pane-mode claude `session_id` was
    /// captured (FSEvents watcher on `~/.claude/projects/`). Used by restore
    /// to judge staleness. None for headless agents (sid is spawn-time there).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id_captured_at: Option<u64>,
}

/// Phase 2.5: cumulative stream-json `usage` counters for a single agent.
/// All counts are monotonic — increments only, never decrements.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UsageTotals {
    #[serde(default)]
    pub input_tokens: u64,
    #[serde(default)]
    pub output_tokens: u64,
    #[serde(default)]
    pub cache_read_input_tokens: u64,
    #[serde(default)]
    pub cache_creation_input_tokens: u64,
    /// Unix-milliseconds timestamp of the most recent usage increment.
    #[serde(default)]
    pub last_updated_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonConfig {
    pub schema: u32,
    #[serde(default)]
    pub idle_park_minutes: u32,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            schema: SCHEMA_VERSION,
            idle_park_minutes: 0,
        }
    }
}

/// Returns `~/.term-mesh/headless/` (creating it lazily is the caller's job).
pub fn headless_root() -> PathBuf {
    if let Ok(p) = std::env::var("TERMMESH_HEADLESS_ROOT") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join(".term-mesh").join("headless")
}

pub fn team_dir(team_uuid: &str) -> PathBuf {
    headless_root().join(team_uuid)
}

pub fn agents_subdir(team_uuid: &str) -> PathBuf {
    team_dir(team_uuid).join("agents")
}

pub fn instructions_subdir(team_uuid: &str) -> PathBuf {
    team_dir(team_uuid).join("instructions")
}

pub fn agent_json_path(team_uuid: &str, agent_name: &str) -> PathBuf {
    agents_subdir(team_uuid).join(format!("{agent_name}.json"))
}

pub fn instructions_path(team_uuid: &str, agent_name: &str) -> PathBuf {
    instructions_subdir(team_uuid).join(format!("{agent_name}.txt"))
}

pub fn team_json_path(team_uuid: &str) -> PathBuf {
    team_dir(team_uuid).join("team.json")
}

pub fn config_path() -> PathBuf {
    headless_root().join("config.json")
}

/// Validate an agent name: no NUL, no '/', not starting with '.', non-empty.
pub fn validate_agent_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("agent name is empty".into());
    }
    if name.starts_with('.') {
        return Err(format!(
            "invalid agent name '{name}': must not start with '.'"
        ));
    }
    if name.contains('/') || name.contains('\0') {
        return Err(format!("invalid agent name '{name}': contains '/' or NUL"));
    }
    Ok(())
}

/// Current unix-seconds timestamp.
pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Generate a fresh lowercase UUIDv4 string.
pub fn new_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Validate a UUID string (lenient: any version, lowercase recommended).
pub fn parse_uuid(s: &str) -> Result<String, String> {
    uuid::Uuid::parse_str(s)
        .map(|u| u.to_string())
        .map_err(|e| format!("invalid uuid '{s}': {e}"))
}

/// Atomically write `bytes` to `path` with permissions `mode`. Creates parent
/// dirs at `0700`. Uses temp+fsync+rename pattern.
pub fn atomic_write(path: &Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        create_dir_secure(parent)?;
    }
    let tmp_path = {
        let stem = path
            .file_name()
            .map(|s| s.to_os_string())
            .unwrap_or_default();
        let mut tmp_name = std::ffi::OsString::from(".");
        tmp_name.push(&stem);
        tmp_name.push(".tmp");
        path.parent()
            .unwrap_or_else(|| Path::new("."))
            .join(tmp_name)
    };

    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp_path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = f.set_permissions(std::fs::Permissions::from_mode(mode));
        }
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp_path, path)?;
    // Best-effort fsync parent.
    if let Some(parent) = path.parent() {
        if let Ok(dir) = std::fs::File::open(parent) {
            let _ = dir.sync_all();
        }
    }
    Ok(())
}

/// Create directory and ancestors with permissions `0700` (best-effort on
/// already-existing nodes).
pub fn create_dir_secure(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

pub fn write_team_meta(meta: &TeamMeta) -> Result<(), String> {
    let path = team_json_path(&meta.team_uuid);
    let bytes = serde_json::to_vec_pretty(meta).map_err(|e| format!("serialize team.json: {e}"))?;
    atomic_write(&path, &bytes, 0o600).map_err(|e| format!("write team.json: {e}"))?;
    Ok(())
}

pub fn write_agent_meta(meta: &AgentMeta) -> Result<(), String> {
    let path = agent_json_path(&meta.team_uuid, &meta.name);
    let bytes =
        serde_json::to_vec_pretty(meta).map_err(|e| format!("serialize agent.json: {e}"))?;
    atomic_write(&path, &bytes, 0o600).map_err(|e| format!("write agent.json: {e}"))?;
    Ok(())
}

pub fn write_instructions(team_uuid: &str, agent_name: &str, bytes: &[u8]) -> Result<(), String> {
    let path = instructions_path(team_uuid, agent_name);
    atomic_write(&path, bytes, 0o600).map_err(|e| format!("write instructions: {e}"))
}

pub fn read_team_meta(team_uuid_or_dir: &Path) -> Result<TeamMeta, String> {
    let p = team_uuid_or_dir.join("team.json");
    let bytes = std::fs::read(&p).map_err(|e| format!("read {}: {e}", p.display()))?;
    let meta: TeamMeta =
        serde_json::from_slice(&bytes).map_err(|e| format!("parse {}: {e}", p.display()))?;
    if !schema_supported(meta.schema) {
        return Err(format!(
            "schema mismatch in {}: expected {}..={}, got {}",
            p.display(),
            MIN_SCHEMA_VERSION,
            SCHEMA_VERSION,
            meta.schema
        ));
    }
    Ok(meta)
}

/// Accept any schema this daemon knows how to read (v1 files parse via serde
/// defaults; newer-than-current files are rejected so we never mis-handle a
/// format written by a future daemon).
pub fn schema_supported(schema: u32) -> bool {
    (MIN_SCHEMA_VERSION..=SCHEMA_VERSION).contains(&schema)
}

pub fn read_agent_meta(team_uuid: &str, agent_name: &str) -> Result<AgentMeta, String> {
    let p = agent_json_path(team_uuid, agent_name);
    let bytes = std::fs::read(&p).map_err(|e| format!("read {}: {e}", p.display()))?;
    let meta: AgentMeta =
        serde_json::from_slice(&bytes).map_err(|e| format!("parse {}: {e}", p.display()))?;
    if !schema_supported(meta.schema) {
        return Err(format!(
            "schema mismatch in {}: expected {}..={}, got {}",
            p.display(),
            MIN_SCHEMA_VERSION,
            SCHEMA_VERSION,
            meta.schema
        ));
    }
    Ok(meta)
}

pub fn read_instructions(team_uuid: &str, agent_name: &str) -> std::io::Result<Vec<u8>> {
    std::fs::read(instructions_path(team_uuid, agent_name))
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

pub fn load_config() -> DaemonConfig {
    let path = config_path();
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice::<DaemonConfig>(&bytes).unwrap_or_default(),
        Err(_) => DaemonConfig::default(),
    }
}

pub fn save_config(cfg: &DaemonConfig) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(cfg).map_err(|e| format!("serialize config: {e}"))?;
    atomic_write(&config_path(), &bytes, 0o600).map_err(|e| format!("write config: {e}"))
}

/// Result row from `list_archived_teams` (read by `list_resumable`).
pub struct ArchivedTeam {
    pub team_uuid: String,
    pub archived_dir: PathBuf,
    pub destroyed_at_from_suffix: u64,
}

/// Scan `~/.term-mesh/headless` for archived team dirs (`*.archived.<ts>`).
/// Returns rows sorted by suffix-timestamp descending.
pub fn list_archived_teams() -> std::io::Result<Vec<ArchivedTeam>> {
    let root = headless_root();
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&root)? {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        let name = entry.file_name();
        let name_str = match name.to_str() {
            Some(s) => s,
            None => continue,
        };
        if let Some((uuid_part, ts_part)) = parse_archived_name(name_str) {
            out.push(ArchivedTeam {
                team_uuid: uuid_part,
                archived_dir: entry.path(),
                destroyed_at_from_suffix: ts_part,
            });
        }
    }
    out.sort_by(|a, b| b.destroyed_at_from_suffix.cmp(&a.destroyed_at_from_suffix));
    Ok(out)
}

/// Parse `<uuid>.archived.<ts>` ⇒ `(uuid, ts)`.
fn parse_archived_name(name: &str) -> Option<(String, u64)> {
    let idx = name.find(".archived.")?;
    let uuid_part = &name[..idx];
    let ts_part = &name[idx + ".archived.".len()..];
    if uuid::Uuid::parse_str(uuid_part).is_err() {
        return None;
    }
    let ts: u64 = ts_part.parse().ok()?;
    Some((uuid_part.to_string(), ts))
}

/// Scan live team dirs (top-level UUID directories without the archived suffix).
/// Returns `(uuid, team_dir_path)` rows.
pub fn list_live_team_dirs() -> std::io::Result<Vec<(String, PathBuf)>> {
    let root = headless_root();
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&root)? {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        let name = entry.file_name();
        let name_str = match name.to_str() {
            Some(s) => s,
            None => continue,
        };
        if name_str.contains(".archived.") {
            continue;
        }
        if uuid::Uuid::parse_str(name_str).is_err() {
            continue;
        }
        out.push((name_str.to_string(), entry.path()));
    }
    Ok(out)
}

/// Rename a live `<uuid>/` to `<uuid>.archived.<ts>/`. Caller already rewrote
/// `team.json:destroyed_at`.
pub fn rename_to_archived(team_uuid: &str, destroyed_at: u64) -> Result<PathBuf, String> {
    let from = team_dir(team_uuid);
    let to = headless_root().join(format!("{team_uuid}.archived.{destroyed_at}"));
    std::fs::rename(&from, &to)
        .map_err(|e| format!("rename {} -> {}: {e}", from.display(), to.display()))?;
    Ok(to)
}

/// Rename an archived dir back to live (resume path).
pub fn rename_to_live(archived_dir: &Path, team_uuid: &str) -> Result<PathBuf, String> {
    let to = headless_root().join(team_uuid);
    std::fs::rename(archived_dir, &to)
        .map_err(|e| format!("rename {} -> {}: {e}", archived_dir.display(), to.display()))?;
    Ok(to)
}

/// Zombie sweep: remove archived pane-mode teams that can never be resumed
/// (leader and every agent lack a `session_id`). Ignores retention age — a
/// pane archive without any session IDs is dead weight and clutters the
/// resume picker. Returns count removed.
///
/// Runs alongside `gc_sweep` at boot and lazily on each `list_resumable`
/// call so stale entries are pruned without waiting for the 7d window.
pub fn sweep_zombie_pane_archives() -> usize {
    let entries = match list_archived_teams() {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let mut removed = 0usize;
    for entry in entries {
        let team_meta = match read_team_meta(&entry.archived_dir) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if team_meta.execution_mode != "pane" {
            continue;
        }
        if team_meta.leader.session_id.is_some() {
            continue;
        }
        let agent_metas = read_all_agent_metas(&entry.archived_dir, &entry.team_uuid);
        let all_sessions_missing =
            team_meta
                .agents
                .iter()
                .all(|name| match agent_metas.get(name) {
                    Some(m) => m.session_id.is_none(),
                    None => true,
                });
        if !all_sessions_missing {
            continue;
        }
        match std::fs::remove_dir_all(&entry.archived_dir) {
            Ok(_) => {
                tracing::info!(
                    "headless gc: removed zombie pane archive {} (uuid={}, no resumable sessions)",
                    entry.archived_dir.display(),
                    entry.team_uuid
                );
                removed += 1;
            }
            Err(e) => {
                tracing::warn!(
                    "headless gc: failed to remove zombie pane archive {}: {e}",
                    entry.archived_dir.display()
                );
            }
        }
    }
    removed
}

/// Sweep live snapshot dirs whose `last_snapshot_at` is older than the
/// archive retention window into the normal archive lifecycle. Covers the
/// "app crashed long ago and the fleet was never restored" case — the dir is
/// renamed to `.archived.<last_snapshot_at>` (with `live` cleared and
/// `destroyed_at` stamped) so `gc_sweep` reclaims it on the same schedule as
/// ordinary archives. Never touches dirs that are missing `live`/
/// `last_snapshot_at` (v1 files, headless live teams, in-progress destroys).
/// Returns count demoted.
pub fn sweep_stale_live_snapshots() -> usize {
    let now = now_unix();
    let live = match list_live_team_dirs() {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let mut demoted = 0usize;
    for (uuid, dir) in live {
        let mut meta = match read_team_meta(&dir) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !meta.live || meta.destroyed_at.is_some() {
            continue;
        }
        let Some(last) = meta.last_snapshot_at else {
            continue;
        };
        if now.saturating_sub(last) < ARCHIVE_RETENTION_SECS {
            continue;
        }
        meta.live = false;
        meta.destroyed_at = Some(last);
        if write_team_meta(&meta).is_err() {
            continue;
        }
        match rename_to_archived(&uuid, last) {
            Ok(to) => {
                tracing::info!(
                    "headless gc: demoted stale live snapshot {uuid} → {} (last_snapshot_at={last})",
                    to.display()
                );
                demoted += 1;
            }
            Err(e) => tracing::warn!("headless gc: demote {uuid} failed: {e}"),
        }
    }
    demoted
}

/// GC sweep: remove archived dirs older than 7d.
/// Returns count removed.
pub fn gc_sweep() -> usize {
    let now = now_unix();
    let entries = match list_archived_teams() {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let mut removed = 0usize;
    for entry in entries {
        let age = now.saturating_sub(entry.destroyed_at_from_suffix);
        if age >= ARCHIVE_RETENTION_SECS {
            match std::fs::remove_dir_all(&entry.archived_dir) {
                Ok(_) => {
                    tracing::info!(
                        "headless gc: removed archived team {} (age {age}s)",
                        entry.archived_dir.display()
                    );
                    removed += 1;
                }
                Err(e) => {
                    tracing::warn!(
                        "headless gc: failed to remove {}: {e}",
                        entry.archived_dir.display()
                    );
                }
            }
        }
    }
    removed
}

/// Startup fixup: for any live `<uuid>/` whose `team.json:destroyed_at != null`,
/// complete the rename to archived. Covers the "daemon crashed mid-destroy"
/// scenario (§7).
pub fn startup_fixup() {
    let live = match list_live_team_dirs() {
        Ok(v) => v,
        Err(_) => return,
    };
    for (uuid, _path) in live {
        // Read team.json safely. Corrupt entries are left alone.
        let meta = match read_team_meta(&team_dir(&uuid)) {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!("headless fixup: skipping {uuid}: {e}");
                continue;
            }
        };
        if let Some(destroyed_at) = meta.destroyed_at {
            tracing::info!(
                "headless fixup: re-archiving live team {uuid} (destroyed_at={destroyed_at})"
            );
            let _ = rename_to_archived(&uuid, destroyed_at);
        }
    }
}

/// Returns a map of `name -> AgentMeta` for every agent file under
/// `<team_uuid>/agents/`. Missing entries listed in `team.json:agents[]` are
/// signalled by absence from the map (caller decides corruption policy).
pub fn read_all_agent_metas(team_uuid_dir: &Path, team_uuid: &str) -> BTreeMap<String, AgentMeta> {
    let dir = team_uuid_dir.join("agents");
    let mut out = BTreeMap::new();
    let read = match std::fs::read_dir(&dir) {
        Ok(r) => r,
        Err(_) => return out,
    };
    for entry in read.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let meta: AgentMeta = match serde_json::from_slice(&bytes) {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!("headless: skip corrupt agent json {}: {e}", path.display());
                continue;
            }
        };
        if !schema_supported(meta.schema) || meta.team_uuid != team_uuid {
            tracing::warn!(
                "headless: skip agent json {} (schema/team mismatch)",
                path.display()
            );
            continue;
        }
        out.insert(meta.name.clone(), meta);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_name_validation() {
        assert!(validate_agent_name("explorer").is_ok());
        assert!(validate_agent_name("explorer-1").is_ok());
        assert!(validate_agent_name("").is_err());
        assert!(validate_agent_name(".hidden").is_err());
        assert!(validate_agent_name("a/b").is_err());
        assert!(validate_agent_name("a\0b").is_err());
    }

    #[test]
    fn archived_name_parser() {
        let (u, ts) =
            parse_archived_name("8f3d1a2b-4c5e-4f6a-9b8c-0d1e2f3a4b5c.archived.1715600000")
                .unwrap();
        assert_eq!(u, "8f3d1a2b-4c5e-4f6a-9b8c-0d1e2f3a4b5c");
        assert_eq!(ts, 1715600000);
        assert!(parse_archived_name("not-a-uuid.archived.123").is_none());
        assert!(
            parse_archived_name("8f3d1a2b-4c5e-4f6a-9b8c-0d1e2f3a4b5c.archived.notnum").is_none()
        );
    }

    #[test]
    fn atomic_write_roundtrip() {
        let tmpdir = tempfile::tempdir().unwrap();
        let path = tmpdir.path().join("subdir").join("file.json");
        atomic_write(&path, b"hello", 0o600).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"hello");
    }

    fn v1_team_json() -> &'static str {
        r#"{
            "schema": 1,
            "team_uuid": "8f3d1a2b-4c5e-4f6a-9b8c-0d1e2f3a4b5c",
            "team_name": "legacy",
            "created_at": 1715600000,
            "destroyed_at": 1715600100,
            "working_directory": "/tmp/x",
            "git_root": null,
            "git_branch_at_create": null,
            "leader": { "mode": "claude", "model": "sonnet", "session_id": null },
            "agents": ["explorer"],
            "worktree": null,
            "execution_mode": "pane",
            "claude_cli_version": null,
            "termmesh_app_version": "0.151.0",
            "app_socket_path_at_create": null,
            "runbook_digest_hash": null
        }"#
    }

    #[test]
    fn schema_v1_team_meta_still_parses() {
        // v1 files predate `live`/`last_snapshot_at`/`layout_workspace_title`;
        // serde defaults must fill them and the schema gate must accept v1.
        let meta: TeamMeta = serde_json::from_str(v1_team_json()).unwrap();
        assert_eq!(meta.schema, 1);
        assert!(schema_supported(meta.schema));
        assert!(!meta.live);
        assert!(meta.last_snapshot_at.is_none());
        assert!(meta.layout_workspace_title.is_none());
        // Future schema is rejected.
        assert!(!schema_supported(SCHEMA_VERSION + 1));
    }

    #[test]
    fn v2_serialization_omits_absent_optionals() {
        let mut meta: TeamMeta = serde_json::from_str(v1_team_json()).unwrap();
        meta.schema = SCHEMA_VERSION;
        let json = serde_json::to_string(&meta).unwrap();
        // skip_serializing_if keeps v2 files free of null-noise for absent fields.
        assert!(!json.contains("last_snapshot_at"));
        assert!(!json.contains("layout_workspace_title"));
        assert!(json.contains("\"live\":false"));
    }

    // NOTE: filesystem-level sweep tests for `sweep_stale_live_snapshots` live
    // in `super::tests` (mod.rs) — they need the shared `ENV_VAR_LOCK` /
    // `scoped_root()` guard for `TERMMESH_HEADLESS_ROOT`, which is private to
    // that test module.

    #[test]
    fn sha256_known_value() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
