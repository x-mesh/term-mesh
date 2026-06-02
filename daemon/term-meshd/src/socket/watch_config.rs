//! Watcher Phase 2 (P6) — per-team watch config persistence (ADR-P6).
//!
//! Persists each team's [`WatchState`] to `<working_dir>/.xm/watch/config.json`,
//! a `{team_id: WatchState}` map, so autonomous watch survives a daemon restart.
//! `.xm/` is gitignored, so configs never enter version control.
//!
//! Contract (consumed by P5 in `main.rs` and by the `watch.*` RPC handlers in
//! `socket.rs`):
//! - [`load_watch_states`] — startup re-registration of enabled teams.
//! - [`save_watch_state`] — `watch.on` / `watch.off` persistence.
//! - [`remove_watch_state`] — drop a team's config entirely.
//!
//! All writes are atomic (`*.tmp` + `fsync` + `rename`), mirroring
//! `headless::meta`. Live counters (`in_flight`, `last_error`) are reset on load
//! so a crash mid-check can never wedge a team in the `in_flight` state.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::drift_watch::WatchState;

/// `<working_dir>/.xm/watch/config.json`.
fn config_path(working_dir: &Path) -> PathBuf {
    working_dir.join(".xm").join("watch").join("config.json")
}

/// Read the full `{team_id: WatchState}` map. A missing or corrupt file yields an
/// empty map (best-effort: a malformed config never crashes the daemon).
fn read_map(working_dir: &Path) -> BTreeMap<String, WatchState> {
    let path = config_path(working_dir);
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
            tracing::warn!("watch_config: corrupt {}: {e}; ignoring", path.display());
            BTreeMap::new()
        }),
        Err(_) => BTreeMap::new(),
    }
}

/// Atomically write the full map, creating `.xm/watch/` as needed.
fn write_map(working_dir: &Path, map: &BTreeMap<String, WatchState>) -> std::io::Result<()> {
    let path = config_path(working_dir);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_vec_pretty(map)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    let tmp = path.with_extension("json.tmp");
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(&json)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, &path)
}

/// Reset live counters that must not survive a restart. A daemon crash mid-check
/// would otherwise reload `in_flight = true` and permanently coalesce away every
/// future tick for that team.
fn sanitize_loaded(mut st: WatchState) -> WatchState {
    st.in_flight = false;
    st.last_error = None;
    // Keep the failure streak paired with last_error: clearing one but not the
    // other would render status as "FAILING" with no error to explain it. The
    // streak is an in-session liveness signal, not durable history, so a restart
    // starts it fresh (last_success_ts is left intact as a factual past timestamp).
    st.consecutive_failures = 0;
    st
}

/// Load all persisted watch states for `working_dir`. Live counters are reset.
/// Returns `(team_id, WatchState)` pairs (deterministic order — `BTreeMap`).
// Consumed by P5's startup re-registration in `main.rs`; no in-crate caller yet.
#[allow(dead_code)]
pub fn load_watch_states(working_dir: &Path) -> Vec<(String, WatchState)> {
    read_map(working_dir)
        .into_iter()
        .map(|(team, st)| (team, sanitize_loaded(st)))
        .collect()
}

/// Persist (insert or replace) one team's watch state. Best-effort — a write
/// failure is logged, never propagated, so it cannot break the RPC handler.
pub fn save_watch_state(working_dir: &Path, team_id: &str, state: &WatchState) {
    let mut map = read_map(working_dir);
    map.insert(team_id.to_string(), state.clone());
    if let Err(e) = write_map(working_dir, &map) {
        tracing::warn!("watch_config: save '{team_id}' failed: {e}");
    }
}

/// Remove one team's watch state. Deletes the config file when the map empties.
// Part of the P5 contract (full deregister path); no in-crate caller yet.
#[allow(dead_code)]
pub fn remove_watch_state(working_dir: &Path, team_id: &str) {
    let mut map = read_map(working_dir);
    if map.remove(team_id).is_none() {
        return;
    }
    if map.is_empty() {
        let _ = std::fs::remove_file(config_path(working_dir));
        return;
    }
    if let Err(e) = write_map(working_dir, &map) {
        tracing::warn!("watch_config: remove '{team_id}' failed: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_state(working_dir: &str) -> WatchState {
        let mut st = WatchState::enabled(
            300,
            Some("executor".into()),
            "codex",
            "gpt-5.5",
            "critic",
            "docs/spec.md",
            working_dir,
        );
        // Live counters that must NOT round-trip back as-is.
        st.in_flight = true;
        st.last_error = Some("boom".into());
        st.consecutive_failures = 4;
        st.check_count = 7;
        st
    }

    #[test]
    fn round_trip_save_then_load_preserves_config() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path();
        let st = sample_state(&wd.to_string_lossy());
        save_watch_state(wd, "standard", &st);

        let loaded = load_watch_states(wd);
        assert_eq!(loaded.len(), 1);
        let (team, got) = &loaded[0];
        assert_eq!(team, "standard");
        assert_eq!(got.enabled, true);
        assert_eq!(got.interval_secs, 300);
        assert_eq!(got.target.as_deref(), Some("executor"));
        assert_eq!(got.cli, "codex");
        assert_eq!(got.model, "gpt-5.5");
        assert_eq!(got.stance, "critic");
        assert_eq!(got.spec, "docs/spec.md");
        // Live counters are sanitized on load.
        assert!(!got.in_flight, "in_flight must reset to false on load");
        assert!(got.last_error.is_none(), "last_error must reset on load");
        assert_eq!(
            got.consecutive_failures, 0,
            "failure streak must reset on load (paired with last_error)"
        );
    }

    #[test]
    fn remove_then_load_absent_and_deletes_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path();
        save_watch_state(wd, "a", &sample_state(&wd.to_string_lossy()));
        save_watch_state(wd, "b", &sample_state(&wd.to_string_lossy()));

        remove_watch_state(wd, "a");
        let loaded = load_watch_states(wd);
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].0, "b");

        // Removing the final entry deletes the config file.
        remove_watch_state(wd, "b");
        assert!(load_watch_states(wd).is_empty());
        assert!(!config_path(wd).exists(), "empty config file should be removed");
    }

    #[test]
    fn missing_file_loads_empty() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load_watch_states(dir.path()).is_empty());
    }

    #[test]
    fn config_is_a_team_keyed_map_with_watchstate_values() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path();
        save_watch_state(wd, "standard", &sample_state(&wd.to_string_lossy()));

        let raw = std::fs::read_to_string(config_path(wd)).unwrap();
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        // {team_id: WatchState} shape.
        assert!(v.get("standard").is_some());
        assert_eq!(v["standard"]["enabled"], true);
        assert_eq!(v["standard"]["interval_secs"], 300);
        assert_eq!(v["standard"]["stance"], "critic");
    }

    #[test]
    fn save_replaces_existing_entry() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path();
        let mut st = sample_state(&wd.to_string_lossy());
        save_watch_state(wd, "standard", &st);
        st.enabled = false;
        st.interval_secs = 999;
        save_watch_state(wd, "standard", &st);

        let loaded = load_watch_states(wd);
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].1.enabled, false);
        assert_eq!(loaded[0].1.interval_secs, 999);
    }
}
