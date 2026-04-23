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
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, RwLock};

use peer_proto::v1::SurfaceInfo;
use tokio::sync::{broadcast, Notify};

use super::pty;

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

        // Reader thread: blocking read(2) loop on the master fd, broadcasting
        // each chunk to subscribers. Exits on EOF or read error; flips the
        // surface's `dead` flag so relay tasks can leave cleanly.
        let reader_surface = surface.clone();
        let master_fd = child.master_fd;
        tokio::task::spawn_blocking(move || {
            let mut buf = [0u8; READ_BUF_SIZE];
            loop {
                match pty::read(master_fd, &mut buf) {
                    Ok(0) => {
                        tracing::info!(
                            "PTY reader EOF on surface {:?}",
                            hex_short(&reader_surface.surface_id)
                        );
                        break;
                    }
                    Ok(n) => {
                        // .send returns Err only when there are no subscribers;
                        // that's expected (nobody attached yet) and not fatal.
                        let _ = tx.send(buf[..n].to_vec());
                    }
                    Err(e) => {
                        tracing::warn!(
                            "PTY read error on surface {:?}: {e}",
                            hex_short(&reader_surface.surface_id)
                        );
                        break;
                    }
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

pub struct PtyManager {
    surfaces: RwLock<HashMap<Vec<u8>, Arc<PtySurface>>>,
}

impl PtyManager {
    pub fn new() -> Self {
        Self {
            surfaces: RwLock::new(HashMap::new()),
        }
    }

    /// Ensure the Phase 2.3B-a default surface exists. Called once at
    /// server startup. If spawn fails (e.g. `$SHELL` not executable),
    /// logs and returns without a surface — the server still runs and
    /// clients see an empty surface list.
    pub fn spawn_default(self: &Arc<Self>, surface_id: Vec<u8>) {
        if self.surfaces.read().unwrap().contains_key(&surface_id) {
            return;
        }
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".into());
        let title = format!("{} -l", shell);
        match PtySurface::spawn(surface_id.clone(), title, &shell, &["-l"], 80, 24) {
            Ok(surface) => {
                self.surfaces
                    .write()
                    .unwrap()
                    .insert(surface_id, surface);
                tracing::info!("spawned default PTY surface");
            }
            Err(e) => {
                tracing::error!("failed to spawn default PTY surface: {e}");
            }
        }
    }

    pub fn list(&self) -> Vec<Arc<PtySurface>> {
        self.surfaces.read().unwrap().values().cloned().collect()
    }

    pub fn get(&self, surface_id: &[u8]) -> Option<Arc<PtySurface>> {
        self.surfaces.read().unwrap().get(surface_id).cloned()
    }

    /// Register a pre-built surface. Used by tests to install deterministic
    /// commands (`/bin/cat` instead of a login shell) without racing env vars.
    #[allow(dead_code)]
    pub fn insert_surface(&self, surface: Arc<PtySurface>) {
        self.surfaces
            .write()
            .unwrap()
            .insert(surface.surface_id.clone(), surface);
    }
}

fn hex_short(bytes: &[u8]) -> String {
    let n = bytes.len().min(4);
    bytes[..n].iter().map(|b| format!("{b:02x}")).collect()
}
