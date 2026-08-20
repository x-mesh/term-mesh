//! Persistence for a daemon host's named-workspace collection (M1).
//!
//! Only identity survives a restart — `{id, name, is_default}` — never
//! the split tree or the PTYs it references (see `layout.rs`'s module
//! doc: shells are children of this process and die with it regardless
//! of persistence). `id` is a random 16-byte value assigned once at
//! workspace creation and never re-derived from the name, so renaming a
//! workspace (a later task) can never change which id a reconnecting
//! client refers to.
//!
//! File: `dirs::data_local_dir()/term-meshd/peer-workspaces.json`, a
//! JSON array of `{id: hex, name, is_default}`. Writes are atomic
//! (`*.tmp` write + `fsync` + `rename`), mirroring `socket::watch_config`.
//! A missing or corrupt file is never fatal for boot — `boot()` falls
//! back to a single fresh default workspace, exactly like a first-ever
//! boot on a clean machine.

use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

use super::connection::random_peer_bytes;

/// Per-process counter mixed into every `save` tmp filename so concurrent
/// `save` calls (multiple connection lifecycles persisting around the same
/// tick) never share a tmp path — see `save`'s doc comment.
static SAVE_TMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// `TERMMESH_PEER_WORKSPACES` — comma-separated workspace names that must
/// exist after boot, beyond the default. Names already present (by name,
/// whether persisted from a prior boot or matching the default) are left
/// alone; anything new is created as an empty workspace.
pub const WORKSPACES_ENV: &str = "TERMMESH_PEER_WORKSPACES";

/// `TERMMESH_PEER_WORKSPACE_TITLE` — overrides the default workspace's
/// display name at every boot. Takes priority over both a persisted name
/// (from a prior boot or a rename) and the hostname-derived fallback a
/// first-ever boot would otherwise pick.
pub const WORKSPACE_TITLE_ENV: &str = "TERMMESH_PEER_WORKSPACE_TITLE";

/// One named workspace's identity, as persisted across daemon restarts.
/// Deliberately does not carry the split tree or surface list — those
/// are runtime-only (see the module doc above and `layout.rs`'s).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedWorkspace {
    pub id: Vec<u8>,
    pub name: String,
    pub is_default: bool,
}

/// Wire shape: `id` as hex so the file stays human-inspectable (matching
/// every other hex-rendered id already logged by `peer::`) instead of a
/// JSON byte-array.
#[derive(Debug, Serialize, Deserialize)]
struct PersistedWorkspaceJson {
    id: String,
    name: String,
    is_default: bool,
}

impl From<&PersistedWorkspace> for PersistedWorkspaceJson {
    fn from(w: &PersistedWorkspace) -> Self {
        Self {
            id: hex::encode(&w.id),
            name: w.name.clone(),
            is_default: w.is_default,
        }
    }
}

/// `dirs::data_local_dir()/term-meshd/peer-workspaces.json`, the
/// production persistence path. Falls back to `/tmp` when the platform
/// data dir is unavailable, matching `agent::default_db_path`'s
/// convention. Callers that need test isolation pass their own path to
/// `load`/`save`/`boot` instead of this one — see their doc comments.
pub fn default_workspaces_path() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("term-meshd")
        .join("peer-workspaces.json")
}

/// Logical ensured-surface records intentionally live outside
/// `peer-workspaces.json`: workspace identity and runner lifecycle have
/// different recovery rules and must never make each other's file unreadable.
pub fn ensured_surfaces_path(workspaces_path: &Path) -> PathBuf {
    workspaces_path.with_file_name("peer-ensured-surfaces.json")
}

pub fn project_presentations_path(workspaces_path: &Path) -> PathBuf {
    workspaces_path.with_file_name("peer-project-presentations.json")
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersistedProjectMember {
    pub name: String,
    pub agent_instance_id: String,
    pub cli: String,
    pub model: String,
    pub agent_type: String,
    pub color: String,
    pub working_directory: String,
    pub surface_id: String,
    pub surface_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersistedProjectPresentation {
    pub owner_peer_id: String,
    pub project_id: String,
    pub team_name: String,
    pub team_uuid: String,
    pub working_directory: String,
    pub project_root: String,
    #[serde(default)]
    pub created_at_unix_secs: u64,
    pub leader_surface_id: String,
    pub members: Vec<PersistedProjectMember>,
    pub revision: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct ProjectPresentationFile {
    version: u32,
    records: Vec<PersistedProjectPresentation>,
}

pub fn load_project_presentations(path: &Path) -> Vec<PersistedProjectPresentation> {
    let Ok(bytes) = std::fs::read(path) else { return Vec::new() };
    let file: ProjectPresentationFile = match serde_json::from_slice(&bytes) {
        Ok(file) => file,
        Err(error) => {
            tracing::warn!(
                "peer-project-presentations.json corrupt ({}): {error}; starting empty",
                path.display()
            );
            return Vec::new();
        }
    };
    if file.version != 1 { return Vec::new(); }
    let mut project_ids = HashSet::new();
    file.records
        .into_iter()
        .filter(|record| {
            !record.project_id.is_empty()
                && !record.team_name.is_empty()
                && !record.team_uuid.is_empty()
                && hex::decode(&record.owner_peer_id).is_ok_and(|id| id.len() == 16)
                && hex::decode(&record.leader_surface_id).is_ok_and(|id| id.len() == 16)
                && project_ids.insert(record.project_id.clone())
        })
        .collect()
}

pub fn save_project_presentations(
    path: &Path,
    records: &[PersistedProjectPresentation],
) -> std::io::Result<()> {
    let bytes = serde_json::to_vec_pretty(&ProjectPresentationFile {
        version: 1,
        records: records.to_vec(),
    })
    .map_err(|error| std::io::Error::new(std::io::ErrorKind::Other, error))?;
    atomic_save(path, &bytes)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedEnsuredSurface {
    pub key: String,
    pub surface_id: Vec<u8>,
    pub spec_hash: [u8; 32],
    pub generation: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct EnsuredSurfaceFile {
    version: u32,
    records: Vec<EnsuredSurfaceJson>,
}

#[derive(Debug, Serialize, Deserialize)]
struct EnsuredSurfaceJson {
    key: String,
    surface_id: String,
    spec_hash: String,
    generation: u64,
}

/// Load valid v1 logical records. A torn/corrupt whole file is treated as an
/// empty registry; malformed individual entries are skipped so one hand-edited
/// record cannot discard every unrelated runner. The stable id is re-derived
/// from `key`, rejecting records from another namespace.
pub fn load_ensured_surfaces(path: &Path) -> Vec<PersistedEnsuredSurface> {
    let Ok(bytes) = std::fs::read(path) else {
        return Vec::new();
    };
    let file: EnsuredSurfaceFile = match serde_json::from_slice(&bytes) {
        Ok(file) => file,
        Err(error) => {
            tracing::warn!(
                "peer-ensured-surfaces.json corrupt ({}): {error}; starting with no logical runner records",
                path.display()
            );
            return Vec::new();
        }
    };
    if file.version != 1 {
        tracing::warn!(
            "peer-ensured-surfaces.json unsupported version {} ({}); starting empty",
            file.version,
            path.display()
        );
        return Vec::new();
    }

    let mut keys = HashSet::new();
    let mut ids = HashSet::new();
    file.records
        .into_iter()
        .filter_map(|record| {
            let surface_id = hex::decode(&record.surface_id).ok()?;
            let spec_hash: [u8; 32] = hex::decode(&record.spec_hash).ok()?.try_into().ok()?;
            if record.key.is_empty()
                || record.key.len() > 256
                || record.generation == 0
                || surface_id != super::surface::surface_id_from_name(&record.key)
                || !keys.insert(record.key.clone())
                || !ids.insert(surface_id.clone())
            {
                tracing::warn!(
                    "skipping invalid ensured-surface record in {}",
                    path.display()
                );
                return None;
            }
            Some(PersistedEnsuredSurface {
                key: record.key,
                surface_id,
                spec_hash,
                generation: record.generation,
            })
        })
        .collect()
}

/// Crash-safe v1 save: unique temp file, file `fsync`, atomic `rename`, then
/// parent-directory `fsync` so the rename itself survives a host crash.
pub fn save_ensured_surfaces(
    path: &Path,
    records: &[PersistedEnsuredSurface],
) -> std::io::Result<()> {
    let file = EnsuredSurfaceFile {
        version: 1,
        records: records
            .iter()
            .map(|record| EnsuredSurfaceJson {
                key: record.key.clone(),
                surface_id: hex::encode(&record.surface_id),
                spec_hash: hex::encode(record.spec_hash),
                generation: record.generation,
            })
            .collect(),
    };
    let bytes = serde_json::to_vec_pretty(&file)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::Other, error))?;
    atomic_save(path, &bytes)
}

fn atomic_save(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let counter = SAVE_TMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = path.with_extension(format!("json.{}.{counter}.tmp", std::process::id()));
    {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    if let Err(error) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(error);
    }
    std::fs::File::open(parent)?.sync_all()
}

/// Load the persisted workspace collection from `path`. A missing file
/// yields an empty vec (the normal first-ever-boot case); a present but
/// unparseable file (bad JSON, or an entry whose `id` isn't valid hex)
/// also yields an empty vec, with a `tracing::warn!` — callers treat both
/// identically via `boot`'s fallback, so a damaged config can never wedge
/// boot, only lose the record of previously-named workspaces.
pub fn load(path: &Path) -> Vec<PersistedWorkspace> {
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(_) => return Vec::new(),
    };
    let parsed: Vec<PersistedWorkspaceJson> = match serde_json::from_slice(&bytes) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(
                "peer-workspaces.json corrupt ({}): {e}; falling back to a single default workspace",
                path.display()
            );
            return Vec::new();
        }
    };
    let mut out = Vec::with_capacity(parsed.len());
    for entry in parsed {
        match hex::decode(&entry.id) {
            Ok(id) => out.push(PersistedWorkspace {
                id,
                name: entry.name,
                is_default: entry.is_default,
            }),
            Err(e) => {
                tracing::warn!(
                    "peer-workspaces.json entry {:?} has invalid id hex ({e}); falling back to a single default workspace",
                    entry.name
                );
                return Vec::new();
            }
        }
    }
    out
}

/// Atomically persist the full workspace collection (`.tmp` write +
/// `fsync` + `rename`), creating the parent directory as needed.
///
/// The tmp filename is unique per call (`pid.counter`), not a fixed
/// `*.json.tmp`: two `save`s racing (e.g. a create and a rename landing
/// close together across connection lifecycles) would otherwise both
/// write through the *same* tmp path, and whichever `rename` won the race
/// — not whichever snapshot was actually newer — is what survived,
/// silently reverting the other write. A unique tmp per call means each
/// `rename` carries its own independent snapshot straight to `path`; the
/// last one to finish still wins (`rename` is atomic, last-writer-wins by
/// design here), but every writer's *own* data always makes it, never a
/// stale one clobbering a fresh one via a shared tmp file.
pub fn save(path: &Path, entries: &[PersistedWorkspace]) -> std::io::Result<()> {
    let json: Vec<PersistedWorkspaceJson> =
        entries.iter().map(PersistedWorkspaceJson::from).collect();
    let bytes = serde_json::to_vec_pretty(&json)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    atomic_save(path, &bytes)
}

/// Parse `TERMMESH_PEER_WORKSPACES` into the list of workspace names the
/// daemon must have after boot, beyond the default: comma-separated,
/// each entry trimmed, blank entries dropped, exact duplicates within
/// the list collapsed to their first occurrence. `None` when unset or
/// empty after parsing — mirrors `surface::parse_surfaces_env`'s
/// unset/empty contract.
///
/// Example: `export TERMMESH_PEER_WORKSPACES="dev,ops"` ensures a `dev`
/// and an `ops` workspace exist, created empty if not already persisted.
pub fn parse_workspaces_env() -> Option<Vec<String>> {
    let raw = std::env::var(WORKSPACES_ENV).ok()?;
    let mut out: Vec<String> = Vec::new();
    for part in raw.split(',') {
        let name = part.trim();
        if name.is_empty() {
            continue;
        }
        if !out.iter().any(|n| n == name) {
            out.push(name.to_string());
        }
    }
    (!out.is_empty()).then_some(out)
}

/// `TERMMESH_PEER_WORKSPACE_TITLE`, trimmed. `None` when unset or blank
/// after trimming (an operator clearing the var to "" opts back into the
/// persisted/hostname-derived name rather than getting an empty title).
pub fn workspace_title_override() -> Option<String> {
    std::env::var(WORKSPACE_TITLE_ENV)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Boot-time reconciliation of the persisted workspace collection:
///
/// 1. Load `path`. A missing or corrupt file (see `load`) starts from
///    nothing, exactly like a first-ever boot.
/// 2. If nothing was loaded, synthesize a fresh default workspace with a
///    random id and `default_name_fallback` as its name. If something
///    was loaded but (through hand-editing or a future bug) no entry is
///    marked `is_default`, promote the first one rather than leaving the
///    collection with no home for un-namespaced control commands.
/// 3. `TERMMESH_PEER_WORKSPACE_TITLE`, if set, overrides the default
///    entry's name — wins over whatever was just loaded or synthesized.
/// 4. `TERMMESH_PEER_WORKSPACES` adds an empty workspace (random id) for
///    every name not already present by name; already-persisted names
///    (from a prior boot, including ones created by this same env var
///    before) are never duplicated.
/// 5. The reconciled result is persisted back to `path`. Best-effort: a
///    save failure is logged and does not block boot — the in-memory
///    result is still returned and used.
pub fn boot(path: &Path, default_name_fallback: &str) -> Vec<PersistedWorkspace> {
    let mut entries = load(path);
    if entries.is_empty() {
        entries.push(PersistedWorkspace {
            id: random_peer_bytes(16),
            name: default_name_fallback.to_string(),
            is_default: true,
        });
    } else if !entries.iter().any(|e| e.is_default) {
        if let Some(first) = entries.first_mut() {
            first.is_default = true;
        }
    }

    if let Some(title) = workspace_title_override() {
        if let Some(default_entry) = entries.iter_mut().find(|e| e.is_default) {
            default_entry.name = title;
        }
    }

    if let Some(names) = parse_workspaces_env() {
        for name in names {
            if entries.iter().any(|e| e.name == name) {
                continue;
            }
            entries.push(PersistedWorkspace {
                id: random_peer_bytes(16),
                name,
                is_default: false,
            });
        }
    }

    if let Err(e) = save(path, &entries) {
        tracing::warn!("peer-workspaces.json save failed ({}): {e}", path.display());
    }
    entries
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Test-only mutex protecting `WORKSPACES_ENV`/`WORKSPACE_TITLE_ENV`
    /// process-global access. Any test that calls `boot` (which reads
    /// both) or the env-parsing helpers directly must hold this for its
    /// duration, or a parallel test's env mutation could leak in.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        fn new() -> Self {
            let lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            std::env::remove_var(WORKSPACES_ENV);
            std::env::remove_var(WORKSPACE_TITLE_ENV);
            Self { _lock: lock }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            std::env::remove_var(WORKSPACES_ENV);
            std::env::remove_var(WORKSPACE_TITLE_ENV);
        }
    }

    fn sample(name: &str, is_default: bool) -> PersistedWorkspace {
        PersistedWorkspace {
            id: random_peer_bytes(16),
            name: name.to_string(),
            is_default,
        }
    }

    #[test]
    fn missing_file_loads_empty() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load(&dir.path().join("peer-workspaces.json")).is_empty());
    }

    #[test]
    fn save_then_load_round_trips_id_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");
        let entries = vec![sample("term-meshd", true), sample("dev", false)];

        save(&path, &entries).unwrap();
        let loaded = load(&path);

        assert_eq!(
            loaded, entries,
            "id/name/is_default must round-trip exactly"
        );
    }

    #[test]
    fn project_presentation_round_trips_exact_surface_ownership() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-project-presentations.json");
        let record = PersistedProjectPresentation {
            owner_peer_id: hex::encode([7u8; 16]),
            project_id: "name:demo".into(),
            team_name: "demo".into(),
            team_uuid: "team-uuid".into(),
            working_directory: "/srv/demo".into(),
            project_root: "/srv/demo".into(),
            created_at_unix_secs: 1_700_000_000,
            leader_surface_id: hex::encode([8u8; 16]),
            members: vec![PersistedProjectMember {
                name: "executor".into(),
                agent_instance_id: "agent-instance".into(),
                cli: "codex".into(),
                model: "gpt-5".into(),
                agent_type: "executor".into(),
                color: "blue".into(),
                working_directory: "/srv/demo".into(),
                surface_id: hex::encode([9u8; 16]),
                surface_type: "agent".into(),
            }],
            revision: 3,
        };

        save_project_presentations(&path, std::slice::from_ref(&record)).unwrap();
        assert_eq!(load_project_presentations(&path), vec![record]);
    }

    #[test]
    fn project_presentation_rejects_invalid_surface_ids_on_load() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-project-presentations.json");
        std::fs::write(
            &path,
            br#"{"version":1,"records":[{"owner_peer_id":"07","project_id":"name:demo","team_name":"demo","team_uuid":"uuid","working_directory":"/srv/demo","project_root":"/srv/demo","leader_surface_id":"08","members":[],"revision":1}]}"#,
        )
        .unwrap();
        assert!(load_project_presentations(&path).is_empty());
    }

    #[test]
    fn rename_persists_across_save_and_reload() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");
        let original = vec![sample("term-meshd", true)];
        save(&path, &original).unwrap();

        // Simulate a rename: load, mutate the name, save back.
        let mut loaded = load(&path);
        assert_eq!(loaded.len(), 1);
        let original_id = loaded[0].id.clone();
        loaded[0].name = "renamed-workspace".to_string();
        save(&path, &loaded).unwrap();

        let reloaded = load(&path);
        assert_eq!(reloaded.len(), 1);
        assert_eq!(
            reloaded[0].id, original_id,
            "id must survive a rename unchanged"
        );
        assert_eq!(reloaded[0].name, "renamed-workspace");
        assert!(reloaded[0].is_default);
    }

    #[test]
    fn corrupt_file_falls_back_to_default_via_boot() {
        let _guard = EnvGuard::new();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");
        std::fs::write(&path, b"{ this is not valid json").unwrap();

        let entries = boot(&path, "fallback-name");

        assert_eq!(entries.len(), 1);
        assert!(entries[0].is_default);
        assert_eq!(entries[0].name, "fallback-name");
        assert_eq!(entries[0].id.len(), 16);

        // The fallback is also persisted, so the damaged file is healed
        // rather than re-triggering the warning on every future boot.
        let reloaded = load(&path);
        assert_eq!(reloaded, entries);
    }

    #[test]
    fn corrupt_entry_id_hex_falls_back_to_default_via_boot() {
        let _guard = EnvGuard::new();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");
        std::fs::write(
            &path,
            br#"[{"id":"not-hex","name":"term-meshd","is_default":true}]"#,
        )
        .unwrap();

        let entries = boot(&path, "fallback-name");

        assert_eq!(entries.len(), 1);
        assert!(entries[0].is_default);
        assert_eq!(entries[0].name, "fallback-name");
    }

    #[test]
    fn missing_file_boots_single_default_with_random_id() {
        let _guard = EnvGuard::new();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");

        let entries = boot(&path, "hostname-fallback");

        assert_eq!(entries.len(), 1);
        assert!(entries[0].is_default);
        assert_eq!(entries[0].name, "hostname-fallback");
        assert_eq!(entries[0].id.len(), 16);
        assert!(path.exists(), "boot must persist the synthesized default");
    }

    #[test]
    fn title_env_overrides_default_name_on_fresh_boot() {
        let _guard = EnvGuard::new();
        std::env::set_var(WORKSPACE_TITLE_ENV, "my-custom-title");
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");

        let entries = boot(&path, "hostname-fallback");

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "my-custom-title");
        assert!(entries[0].is_default);
    }

    #[test]
    fn title_env_overrides_persisted_default_name() {
        let _guard = EnvGuard::new();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");
        let existing = vec![sample("previously-renamed", true)];
        save(&path, &existing).unwrap();
        let original_id = existing[0].id.clone();

        std::env::set_var(WORKSPACE_TITLE_ENV, "override-title");
        let entries = boot(&path, "hostname-fallback");

        assert_eq!(entries.len(), 1);
        assert_eq!(
            entries[0].id, original_id,
            "override must not change the id"
        );
        assert_eq!(entries[0].name, "override-title");
    }

    #[test]
    fn blank_title_env_is_ignored() {
        let _guard = EnvGuard::new();
        std::env::set_var(WORKSPACE_TITLE_ENV, "   ");
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");

        let entries = boot(&path, "hostname-fallback");

        assert_eq!(
            entries[0].name, "hostname-fallback",
            "blank override must not apply"
        );
    }

    #[test]
    fn workspaces_env_creates_new_entries_without_duplicating_persisted() {
        let _guard = EnvGuard::new();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");
        let existing = vec![sample("term-meshd", true), sample("dev", false)];
        save(&path, &existing).unwrap();
        let dev_id = existing
            .iter()
            .find(|e| e.name == "dev")
            .unwrap()
            .id
            .clone();

        std::env::set_var(WORKSPACES_ENV, "dev,ops");
        let entries = boot(&path, "hostname-fallback");

        assert_eq!(
            entries.len(),
            3,
            "dev must not be duplicated; ops must be added"
        );
        let dev = entries
            .iter()
            .find(|e| e.name == "dev")
            .expect("dev present");
        assert_eq!(dev.id, dev_id, "pre-existing dev workspace keeps its id");
        assert!(!dev.is_default);
        let ops = entries
            .iter()
            .find(|e| e.name == "ops")
            .expect("ops present");
        assert!(!ops.is_default);
        assert_eq!(ops.id.len(), 16);

        // Persisted so a second boot with the same env sees no new entries.
        std::env::set_var(WORKSPACES_ENV, "dev,ops");
        let second_boot = boot(&path, "hostname-fallback");
        assert_eq!(
            second_boot.len(),
            3,
            "second boot must not create duplicates"
        );
    }

    #[test]
    fn parse_workspaces_env_trims_dedupes_and_drops_blanks() {
        let _guard = EnvGuard::new();
        std::env::set_var(WORKSPACES_ENV, " dev ,ops,dev,,  ");
        assert_eq!(
            parse_workspaces_env(),
            Some(vec!["dev".to_string(), "ops".to_string()])
        );
    }

    #[test]
    fn parse_workspaces_env_unset_is_none() {
        let _guard = EnvGuard::new();
        assert_eq!(parse_workspaces_env(), None);
    }

    #[test]
    fn parse_workspaces_env_blank_only_is_none() {
        let _guard = EnvGuard::new();
        std::env::set_var(WORKSPACES_ENV, " , , ");
        assert_eq!(parse_workspaces_env(), None);
    }

    /// P2-2 regression: `save` used to open a fixed `*.json.tmp` path, so
    /// concurrent saves (multiple connection lifecycles persisting around
    /// the same tick) could both write through the SAME tmp file — one
    /// `rename` could pick up the other's half-written bytes, or an older
    /// snapshot could win the rename race and silently clobber a newer
    /// one. With a unique tmp name per call, every writer's `rename`
    /// carries its own complete, independent snapshot straight to `path`;
    /// the file on disk after all writers finish must always be exactly
    /// one writer's full, valid snapshot — never a corrupt blend, and
    /// never a leftover tmp file.
    #[test]
    fn concurrent_saves_never_corrupt_the_final_file() {
        use std::sync::Arc;
        use std::thread;

        let dir = tempfile::tempdir().unwrap();
        let path = Arc::new(dir.path().join("peer-workspaces.json"));

        let handles: Vec<_> = (0..16)
            .map(|i| {
                let path = Arc::clone(&path);
                thread::spawn(move || {
                    let entries = vec![sample(&format!("writer-{i}"), true)];
                    save(&path, &entries).unwrap();
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }

        let loaded = load(&path);
        assert_eq!(
            loaded.len(),
            1,
            "final file must be exactly one writer's complete snapshot, not a merge/corruption"
        );
        assert!(
            loaded[0].name.starts_with("writer-"),
            "final entry must be a genuine writer's data: {:?}",
            loaded[0].name
        );
        assert!(loaded[0].is_default);
        assert_eq!(loaded[0].id.len(), 16);

        // No stray tmp files left behind — a unique name per call means no
        // two writers' tmp paths ever collided.
        let leftover: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
            .collect();
        assert!(
            leftover.is_empty(),
            "no tmp files should survive concurrent saves: {leftover:?}"
        );
    }

    /// Two `save` calls in direct succession must never reuse the same tmp
    /// filename — the collision `SAVE_TMP_COUNTER` exists to rule out.
    #[test]
    fn successive_saves_use_distinct_tmp_names() {
        let before = SAVE_TMP_COUNTER.load(Ordering::Relaxed);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-workspaces.json");

        save(&path, &[sample("a", true)]).unwrap();
        save(&path, &[sample("b", true)]).unwrap();

        let after = SAVE_TMP_COUNTER.load(Ordering::Relaxed);
        assert!(
            after - before >= 2,
            "each save must consume its own counter value"
        );
    }

    #[test]
    fn ensured_records_use_separate_versioned_namespace() {
        let dir = tempfile::tempdir().unwrap();
        let workspace_path = dir.path().join("peer-workspaces.json");
        let ensured_path = ensured_surfaces_path(&workspace_path);
        let key = "runner";
        let record = PersistedEnsuredSurface {
            key: key.into(),
            surface_id: super::super::surface::surface_id_from_name(key),
            spec_hash: [7; 32],
            generation: 3,
        };

        save_ensured_surfaces(&ensured_path, std::slice::from_ref(&record)).unwrap();

        assert_eq!(load_ensured_surfaces(&ensured_path), vec![record]);
        assert!(!workspace_path.exists());
        assert_eq!(
            ensured_path.file_name().unwrap(),
            "peer-ensured-surfaces.json"
        );
    }

    #[test]
    fn ensured_load_recovers_valid_records_from_partially_invalid_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-ensured-surfaces.json");
        let key = "valid-runner";
        let valid_id = super::super::surface::surface_id_from_name(key);
        std::fs::write(
            &path,
            format!(
                r#"{{"version":1,"records":[{{"key":"{key}","surface_id":"{}","spec_hash":"{}","generation":2}},{{"key":"bad","surface_id":"00","spec_hash":"nope","generation":0}}]}}"#,
                hex::encode(&valid_id),
                hex::encode([9; 32])
            ),
        )
        .unwrap();

        let loaded = load_ensured_surfaces(&path);
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].key, key);
        assert_eq!(loaded[0].generation, 2);
    }

    #[test]
    fn corrupt_ensured_file_recovers_as_empty_without_touching_workspaces() {
        let dir = tempfile::tempdir().unwrap();
        let workspace_path = dir.path().join("peer-workspaces.json");
        let ensured_path = ensured_surfaces_path(&workspace_path);
        save(&workspace_path, &[sample("kept", true)]).unwrap();
        std::fs::write(&ensured_path, b"{torn").unwrap();

        assert!(load_ensured_surfaces(&ensured_path).is_empty());
        assert_eq!(load(&workspace_path)[0].name, "kept");
    }
}
