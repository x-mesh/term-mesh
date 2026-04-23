//! Host-side surfaces backed by real PTYs (Phase 2.3B).
//!
//! A `PtySurface` wraps a forked child attached to a PTY master fd.
//! PTY output is fan-out to all attached clients via `tokio::broadcast`;
//! client input goes to the master via blocking `write(2)`.
//!
//! `PtyManager` owns the registry of live surfaces. For Phase 2.3B-a
//! we eagerly spawn a single default surface running `$SHELL -l`, with
//! a stable surface_id so clients can list + attach deterministically.

use std::collections::HashMap;
use std::os::unix::io::{AsRawFd, RawFd};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, RwLock};

use peer_proto::v1::SurfaceInfo;
use tokio::io::unix::AsyncFd;
use tokio::io::Interest;
use tokio::sync::{broadcast, Notify};

use super::pty;

/// Wrapper so a PTY master fd can be handed to `AsyncFd::new` without
/// implying ownership — closing the fd is the surface's Drop's job.
#[derive(Debug)]
struct BorrowedMasterFd(RawFd);

impl AsRawFd for BorrowedMasterFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

const READ_BUF_SIZE: usize = 4096;
/// Fan-out channel capacity. If a slow subscriber falls behind by this many
/// chunks, it starts getting `RecvError::Lagged` on `recv()`; the connection
/// layer handles that as a gap (eventual reconnect will re-snapshot).
const BROADCAST_CAPACITY: usize = 1024;

pub struct PtySurface {
    pub surface_id: Vec<u8>,
    pub title: String,
    pub workspace_name: String,
    pub cols: AtomicU32,
    pub rows: AtomicU32,
    /// The authoritative broadcast sender. Subscribers are created via
    /// `.subscribe()`; the reader task owns a cloned sender for fan-out.
    pub broadcast_tx: broadcast::Sender<Vec<u8>>,
    /// Set true when the PTY reader has observed EOF or the child died.
    /// Subscribers should detach when this flips.
    pub dead: AtomicBool,
    /// Notified when `dead` flips; lets relay tasks exit promptly without
    /// polling the flag.
    pub dead_notify: Notify,
    master_fd: RawFd,
    pid: libc::pid_t,
}

impl PtySurface {
    pub fn spawn(
        surface_id: Vec<u8>,
        title: String,
        command: &str,
        args: &[&str],
        cols: u16,
        rows: u16,
    ) -> std::io::Result<Arc<Self>> {
        let child = pty::spawn(command, args, cols, rows)?;
        pty::set_nonblocking(child.master_fd)?;
        let (tx, _rx) = broadcast::channel::<Vec<u8>>(BROADCAST_CAPACITY);

        let surface = Arc::new(PtySurface {
            surface_id: surface_id.clone(),
            title,
            workspace_name: "peer-host".into(),
            cols: AtomicU32::new(cols as u32),
            rows: AtomicU32::new(rows as u32),
            broadcast_tx: tx.clone(),
            dead: AtomicBool::new(false),
            dead_notify: Notify::new(),
            master_fd: child.master_fd,
            pid: child.pid,
        });

        // Reader task: tokio::spawn (not spawn_blocking) with AsyncFd so the
        // reactor can cancel it on runtime shutdown. The blocking variant used
        // in 2.3B-a hung runtime drop whenever the child was long-lived,
        // because an in-flight `read(2)` can't be interrupted from outside.
        let reader_surface = surface.clone();
        let master_fd = child.master_fd;
        tokio::spawn(async move {
            let async_fd = match AsyncFd::with_interest(
                BorrowedMasterFd(master_fd),
                Interest::READABLE,
            ) {
                Ok(fd) => fd,
                Err(e) => {
                    tracing::error!("AsyncFd registration failed: {e}");
                    reader_surface.dead.store(true, Ordering::Release);
                    reader_surface.dead_notify.notify_waiters();
                    return;
                }
            };

            let mut buf = vec![0u8; READ_BUF_SIZE];
            loop {
                let mut guard = match async_fd.readable().await {
                    Ok(g) => g,
                    Err(e) => {
                        tracing::warn!(
                            "AsyncFd readable error on surface {:?}: {e}",
                            hex_short(&reader_surface.surface_id)
                        );
                        break;
                    }
                };

                let child_pid = reader_surface.pid;
                let result = guard.try_io(|inner| {
                    // Safety: libc::read on a registered, nonblocking fd.
                    let n = unsafe {
                        libc::read(
                            inner.as_raw_fd(),
                            buf.as_mut_ptr() as *mut _,
                            buf.len(),
                        )
                    };
                    if n < 0 {
                        let err = std::io::Error::last_os_error();
                        match err.raw_os_error() {
                            // AsyncFd will re-register and wait for readability.
                            Some(libc::EAGAIN) => Err(err),
                            Some(libc::EIO) => {
                                // macOS reports EIO both for "child has
                                // exited" AND transiently during the brief
                                // gap between fork and exec. Distinguish
                                // via WNOHANG waitpid: if the child is still
                                // running, treat EIO as EAGAIN (ask AsyncFd
                                // to re-register). If it has exited, real EOF.
                                if pty::child_has_exited(child_pid) {
                                    Ok(0)
                                } else {
                                    Err(std::io::Error::from_raw_os_error(libc::EAGAIN))
                                }
                            }
                            _ => Err(err),
                        }
                    } else {
                        Ok(n as usize)
                    }
                });

                match result {
                    Ok(Ok(0)) => {
                        tracing::info!(
                            "PTY reader EOF on surface {:?}",
                            hex_short(&reader_surface.surface_id)
                        );
                        break;
                    }
                    Ok(Ok(n)) => {
                        // Err only means "no subscribers", which is fine.
                        let _ = tx.send(buf[..n].to_vec());
                    }
                    Ok(Err(e)) => {
                        tracing::warn!(
                            "PTY read error on surface {:?}: {e}",
                            hex_short(&reader_surface.surface_id)
                        );
                        break;
                    }
                    Err(_would_block) => continue,
                }
            }
            reader_surface.dead.store(true, Ordering::Release);
            reader_surface.dead_notify.notify_waiters();
        });

        Ok(surface)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Vec<u8>> {
        self.broadcast_tx.subscribe()
    }

    pub fn write(&self, bytes: &[u8]) -> std::io::Result<usize> {
        pty::write(self.master_fd, bytes)
    }

    pub fn resize(&self, cols: u16, rows: u16) -> std::io::Result<()> {
        pty::resize(self.master_fd, cols, rows)?;
        self.cols.store(cols as u32, Ordering::Relaxed);
        self.rows.store(rows as u32, Ordering::Relaxed);
        Ok(())
    }

    pub fn info(&self) -> SurfaceInfo {
        SurfaceInfo {
            surface_id: self.surface_id.clone(),
            workspace_name: self.workspace_name.clone(),
            title: self.title.clone(),
            cols: self.cols.load(Ordering::Relaxed),
            rows: self.rows.load(Ordering::Relaxed),
            surface_type: "terminal".into(),
            attachable: !self.dead.load(Ordering::Acquire),
        }
    }
}

impl Drop for PtySurface {
    fn drop(&mut self) {
        pty::teardown(self.master_fd, self.pid);
    }
}

#[derive(Clone, Debug)]
pub struct SpawnSpec {
    pub title: String,
    pub command: String,
    pub args: Vec<String>,
    pub cols: u16,
    pub rows: u16,
}

pub struct PtyManager {
    surfaces: RwLock<HashMap<Vec<u8>, Arc<PtySurface>>>,
    /// Registered "how to respawn this surface" specs keyed by surface_id.
    /// `insert_surface` (test-only path) does not populate this; production
    /// surfaces registered via `spawn_default` do.
    specs: RwLock<HashMap<Vec<u8>, SpawnSpec>>,
}

/// Namespace UUID used to derive stable 16-byte `surface_id`s from
/// user-friendly names. Deterministic across runs so a client can
/// reconnect to the same logical surface after a daemon restart.
const SURFACE_NAMESPACE: uuid::Uuid = uuid::Uuid::from_bytes([
    0xf5, 0x75, 0x6e, 0x86, 0xa7, 0xde, 0x49, 0x3b, 0x9d, 0x43, 0x12, 0x95, 0xed, 0xc8, 0x2a, 0xd0,
]);

/// Stable 16-byte id derived from a human name via UUIDv5.
/// Collision-resistant regardless of name length.
pub fn surface_id_from_name(name: &str) -> Vec<u8> {
    uuid::Uuid::new_v5(&SURFACE_NAMESPACE, name.as_bytes())
        .as_bytes()
        .to_vec()
}

/// Parse `TERMMESH_PEER_SURFACES` into (name, shell-command) pairs.
///
/// Format: one `name=cmd` entry per line. Newline as the separator lets
/// commands use `;` freely (for `while :; do …; done` style loops). Each
/// command string is executed via `/bin/sh -c <cmd>` so quoting and
/// expansion work naturally. Empty / malformed lines are silently skipped.
/// Returns `None` when the env var is unset or parses to nothing.
///
/// Example (bash / zsh):
///
/// ```text
/// export TERMMESH_PEER_SURFACES='shell=/bin/zsh -l
/// clock=while :; do date; sleep 1; done
/// uptime=while :; do uptime; sleep 2; done'
/// ```
pub fn parse_surfaces_env() -> Option<Vec<(String, String)>> {
    let raw = std::env::var("TERMMESH_PEER_SURFACES").ok()?;
    let mut out = Vec::new();
    for entry in raw.split('\n') {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        let Some((name, cmd)) = entry.split_once('=') else {
            continue;
        };
        let (name, cmd) = (name.trim(), cmd.trim());
        if name.is_empty() || cmd.is_empty() {
            continue;
        }
        out.push((name.to_string(), cmd.to_string()));
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn default_shell_cmd() -> String {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".into());
    format!("{shell} -l")
}

impl PtyManager {
    pub fn new() -> Self {
        Self {
            surfaces: RwLock::new(HashMap::new()),
            specs: RwLock::new(HashMap::new()),
        }
    }

    /// Spawn every surface declared by `TERMMESH_PEER_SURFACES`, falling
    /// back to a single "shell" surface running `$SHELL -l`. Called once
    /// at server startup. Each registered spec is eligible for auto-respawn
    /// via `get_or_respawn`.
    pub fn spawn_from_config(self: &Arc<Self>) {
        let entries = parse_surfaces_env()
            .unwrap_or_else(|| vec![("shell".to_string(), default_shell_cmd())]);
        for (name, cmd) in entries {
            let surface_id = surface_id_from_name(&name);
            if self.surfaces.read().unwrap().contains_key(&surface_id) {
                continue;
            }
            let spec = SpawnSpec {
                title: name,
                command: "/bin/sh".into(),
                args: vec!["-c".into(), cmd],
                cols: 80,
                rows: 24,
            };
            self.register_and_spawn(surface_id, spec);
        }
    }

    /// Register a respawn spec under `surface_id` and spawn its first
    /// instance. Errors are logged; the server runs on regardless.
    pub fn register_and_spawn(&self, surface_id: Vec<u8>, spec: SpawnSpec) {
        match spawn_from_spec(&surface_id, &spec) {
            Ok(surface) => {
                self.surfaces
                    .write()
                    .unwrap()
                    .insert(surface_id.clone(), surface);
                self.specs.write().unwrap().insert(surface_id, spec);
                tracing::info!("spawned default PTY surface");
            }
            Err(e) => {
                tracing::error!("failed to spawn default PTY surface: {e}");
            }
        }
    }

    pub fn list(&self) -> Vec<Arc<PtySurface>> {
        let mut v: Vec<Arc<PtySurface>> = self.surfaces.read().unwrap().values().cloned().collect();
        // Stable ordering for UI/CLI display.
        v.sort_by(|a, b| a.title.cmp(&b.title));
        v
    }

    /// Return a live surface for `surface_id`, respawning if the
    /// previously-registered instance has exited. Returns `None` when the
    /// id is unknown (no surface ever registered) or when respawn fails.
    pub fn get_or_respawn(&self, surface_id: &[u8]) -> Option<Arc<PtySurface>> {
        if let Some(s) = self.surfaces.read().unwrap().get(surface_id) {
            if !s.dead.load(Ordering::Acquire) {
                return Some(s.clone());
            }
        }

        let spec = self.specs.read().unwrap().get(surface_id).cloned()?;

        let mut surfaces = self.surfaces.write().unwrap();
        // Re-check under the write lock: another caller may have just
        // respawned between our read-lock check and now.
        if let Some(s) = surfaces.get(surface_id) {
            if !s.dead.load(Ordering::Acquire) {
                return Some(s.clone());
            }
        }
        surfaces.remove(surface_id);

        match spawn_from_spec(surface_id, &spec) {
            Ok(surface) => {
                surfaces.insert(surface_id.to_vec(), surface.clone());
                tracing::info!(
                    "respawned surface after exit: {}",
                    hex_short(surface_id)
                );
                Some(surface)
            }
            Err(e) => {
                tracing::error!("respawn failed for {}: {e}", hex_short(surface_id));
                None
            }
        }
    }

    /// Register a pre-built surface. Used by tests to install deterministic
    /// commands (`/bin/cat` instead of a login shell) without racing env vars.
    /// Does NOT register a respawn spec; tests that need respawn must use
    /// `register_and_spawn`.
    #[allow(dead_code)]
    pub fn insert_surface(&self, surface: Arc<PtySurface>) {
        self.surfaces
            .write()
            .unwrap()
            .insert(surface.surface_id.clone(), surface);
    }
}

fn spawn_from_spec(surface_id: &[u8], spec: &SpawnSpec) -> std::io::Result<Arc<PtySurface>> {
    let arg_refs: Vec<&str> = spec.args.iter().map(String::as_str).collect();
    PtySurface::spawn(
        surface_id.to_vec(),
        spec.title.clone(),
        &spec.command,
        &arg_refs,
        spec.cols,
        spec.rows,
    )
}

fn hex_short(bytes: &[u8]) -> String {
    let n = bytes.len().min(4);
    bytes[..n].iter().map(|b| format!("{b:02x}")).collect()
}
