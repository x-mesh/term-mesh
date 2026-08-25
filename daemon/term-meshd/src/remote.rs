//! Mobile remote-control exposure registry.
//!
//! Design: `docs/mobile-remote-control.md` §4.1. A surface (GUI pane or daemon
//! PTY) is only reachable from the mobile listener after it has been
//! registered here, which `tm-agent remote on` (the `/rc` skill) does from
//! inside the pane. The registry is in-memory: a daemon restart forgets every
//! entry and the operator re-runs `/rc on`.
//!
//! This module deliberately depends on nothing else in the crate so the
//! integration test in `tests/remote_registry.rs` can include it with
//! `#[path]` the way the sync tests do.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

/// Default lifetime of an exposure. `/rc on --ttl` overrides it.
pub const DEFAULT_TTL_SECS: u64 = 24 * 60 * 60;
/// Longest lifetime accepted; longer requests are clamped, not rejected.
pub const MAX_TTL_SECS: u64 = 7 * 24 * 60 * 60;
/// Shortest lifetime accepted; shorter requests are clamped up.
pub const MIN_TTL_SECS: u64 = 60;
/// Upper bound on surface ids (UUID or hex id; both are far shorter).
pub const MAX_SURFACE_ID_BYTES: usize = 128;

/// Mobile listener bind address when `TERM_MESH_MOBILE_ADDR` is unset.
pub const DEFAULT_LISTENER_ADDR: &str = "127.0.0.1:9877";
pub const ENV_LISTENER_ENABLED: &str = "TERM_MESH_MOBILE_ENABLED";
pub const ENV_LISTENER_ADDR: &str = "TERM_MESH_MOBILE_ADDR";

/// What the mobile page is allowed to do with the target.
///
/// `leader` routes text through the durable leader request board
/// (`team.leader.send`); `pane` types it straight into the surface
/// (`surface.send_text`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TargetKind {
    Leader,
    Pane,
}

/// Which keys the mobile page may send. `safe` is the fixed allowlist in
/// `docs/mobile-remote-control.md` §6; `none` disables `/key` entirely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KeysPolicy {
    Safe,
    None,
}

impl Default for KeysPolicy {
    fn default() -> Self {
        KeysPolicy::Safe
    }
}

/// One exposed surface.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// GUI pane: the panel UUID the app injects as `TERMMESH_SURFACE_ID`.
    /// Daemon surface: the hex id from `identity_environment`.
    pub surface_id: String,
    pub kind: TargetKind,
    /// Required for `kind = leader`: the team whose durable request board
    /// receives the text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team_name: Option<String>,
    #[serde(default)]
    pub agent_cli: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub cwd: String,
    /// The app Unix socket that owns the surface (GUI panes). A daemon-owned
    /// surface has none; the listener reads it in-process instead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_socket: Option<String>,
    #[serde(default)]
    pub keys: KeysPolicy,
    /// Who registered it: the local user for the CLI, the tailnet login for
    /// an HTTP caller. Informational; never used for authorization.
    pub owner: String,
    pub created_at: u64,
    pub expires_at: u64,
    /// Leader panes only: the app's leader-request capability token
    /// (`TERMMESH_LEADER_REQUEST_TOKEN`), needed to list the durable board.
    /// Never serialized: it stays inside the daemon.
    #[serde(default, skip_serializing)]
    pub leader_request_token: Option<String>,
}

impl Entry {
    pub fn is_expired(&self, now: u64) -> bool {
        now >= self.expires_at
    }
}

/// Everything `remote.on` needs. Re-registering a surface replaces the entry
/// and restarts its TTL, so `/rc on` doubles as "extend".
#[derive(Debug, Clone, Default, Deserialize)]
pub struct EnableSpec {
    pub surface_id: String,
    #[serde(default = "default_kind")]
    pub kind: TargetKind,
    #[serde(default)]
    pub team_name: Option<String>,
    #[serde(default)]
    pub agent_cli: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub app_socket: Option<String>,
    #[serde(default)]
    pub keys: KeysPolicy,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub ttl_secs: Option<u64>,
    #[serde(default)]
    pub leader_request_token: Option<String>,
}

fn default_kind() -> TargetKind {
    TargetKind::Pane
}

impl Default for TargetKind {
    fn default() -> Self {
        TargetKind::Pane
    }
}

impl EnableSpec {
    /// Reject what the listener could never serve. Returns the clamped TTL.
    pub fn validate(&self) -> Result<u64, String> {
        let id = self.surface_id.trim();
        if id.is_empty() {
            return Err("surface_id is required".into());
        }
        if id.len() > MAX_SURFACE_ID_BYTES {
            return Err("surface_id is too long".into());
        }
        if !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
        {
            return Err("surface_id must be alphanumeric, '-', '_' or '.'".into());
        }
        if self.kind == TargetKind::Leader
            && self
                .team_name
                .as_deref()
                .map(str::trim)
                .unwrap_or("")
                .is_empty()
        {
            return Err("kind=leader requires team_name".into());
        }
        if let Some(sock) = self.app_socket.as_deref() {
            if !sock.starts_with('/') {
                return Err("app_socket must be an absolute path".into());
            }
        }
        Ok(self
            .ttl_secs
            .unwrap_or(DEFAULT_TTL_SECS)
            .clamp(MIN_TTL_SECS, MAX_TTL_SECS))
    }
}

/// In-memory registry keyed by surface id.
#[derive(Debug, Default)]
pub struct Registry {
    entries: HashMap<String, Entry>,
    /// Registration order. `created_at` has second resolution, so two
    /// `/rc on` in the same second would otherwise list in id order.
    order: HashMap<String, u64>,
    next_seq: u64,
}

pub type SharedRegistry = Arc<Mutex<Registry>>;

pub fn new_registry() -> SharedRegistry {
    Arc::new(Mutex::new(Registry::default()))
}

impl Registry {
    #[allow(dead_code)] // tests construct it directly; the daemon uses `new_registry`
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert or replace. The caller validates first; an invalid spec here is
    /// a programming error, surfaced as `Err` rather than a panic so the RPC
    /// layer can still answer.
    pub fn upsert(&mut self, spec: EnableSpec, now: u64) -> Result<Entry, String> {
        let ttl = spec.validate()?;
        let surface_id = spec.surface_id.trim().to_string();
        let entry = Entry {
            surface_id: surface_id.clone(),
            kind: spec.kind,
            team_name: spec
                .team_name
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty()),
            agent_cli: spec.agent_cli.trim().to_string(),
            title: spec.title.trim().to_string(),
            cwd: spec.cwd.trim().to_string(),
            app_socket: spec.app_socket,
            keys: spec.keys,
            owner: spec
                .owner
                .map(|o| o.trim().to_string())
                .filter(|o| !o.is_empty())
                .unwrap_or_else(|| "local".to_string()),
            created_at: now,
            expires_at: now.saturating_add(ttl),
            leader_request_token: spec
                .leader_request_token
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty()),
        };
        self.next_seq += 1;
        self.order.insert(surface_id.clone(), self.next_seq);
        self.entries.insert(surface_id, entry.clone());
        Ok(entry)
    }

    pub fn remove(&mut self, surface_id: &str) -> bool {
        self.order.remove(surface_id.trim());
        self.entries.remove(surface_id.trim()).is_some()
    }

    pub fn get(&self, surface_id: &str) -> Option<&Entry> {
        self.entries.get(surface_id.trim())
    }

    /// Live entry only: an expired one reads as absent so a stale exposure
    /// can never be served, even before the next prune.
    pub fn get_live(&self, surface_id: &str, now: u64) -> Option<&Entry> {
        self.get(surface_id).filter(|e| !e.is_expired(now))
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Entries in registration order, oldest first. Re-registering moves an
    /// entry to the end.
    pub fn list(&self) -> Vec<Entry> {
        let mut out: Vec<Entry> = self.entries.values().cloned().collect();
        out.sort_by_key(|e| self.order.get(&e.surface_id).copied().unwrap_or(0));
        out
    }

    /// Drop expired entries and entries whose owner is gone (`alive` says
    /// whether the surface can still be reached). Returns the removed ids so
    /// the RPC can report what it dropped.
    pub fn prune<F>(&mut self, now: u64, alive: F) -> Vec<String>
    where
        F: Fn(&Entry) -> bool,
    {
        let dead: Vec<String> = self
            .entries
            .values()
            .filter(|e| e.is_expired(now) || !alive(e))
            .map(|e| e.surface_id.clone())
            .collect();
        for id in &dead {
            self.entries.remove(id);
            self.order.remove(id);
        }
        let mut dead = dead;
        dead.sort();
        dead
    }
}

pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// A GUI entry is reachable while its app socket still exists as a socket.
/// Daemon-owned entries (no `app_socket`) are the listener's own concern and
/// count as alive here.
pub fn app_socket_alive(entry: &Entry) -> bool {
    match entry.app_socket.as_deref() {
        None => true,
        Some(path) => std::fs::metadata(path)
            .map(|m| {
                use std::os::unix::fs::FileTypeExt;
                m.file_type().is_socket()
            })
            .unwrap_or(false),
    }
}

/// `TERM_MESH_MOBILE_ENABLED=1|true` turns the listener on. Anything else,
/// including unset, leaves it off: exposure is opt-in.
pub fn listener_enabled() -> bool {
    std::env::var(ENV_LISTENER_ENABLED)
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Bind address for the listener. Only loopback is accepted: the tailnet
/// reaches it through Tailscale Serve, never directly.
pub fn listener_addr() -> Result<SocketAddr, String> {
    let raw = std::env::var(ENV_LISTENER_ADDR)
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_LISTENER_ADDR.to_string());
    parse_loopback_addr(&raw)
}

pub fn parse_loopback_addr(raw: &str) -> Result<SocketAddr, String> {
    let addr: SocketAddr = raw
        .trim()
        .parse()
        .map_err(|e| format!("{ENV_LISTENER_ADDR}={raw:?} is not host:port: {e}"))?;
    if !addr.ip().is_loopback() {
        return Err(format!(
            "{ENV_LISTENER_ADDR}={raw:?} is not a loopback address; the mobile listener only binds 127.0.0.1/::1 (expose it with `tailscale serve`)"
        ));
    }
    Ok(addr)
}

/// Where the mobile page for one surface lives on the loopback listener.
/// Phase 2 prefixes the Tailscale Serve hostname on the CLI side.
pub fn target_url(addr: &SocketAddr, surface_id: &str) -> String {
    format!("http://{addr}/t/{surface_id}")
}
