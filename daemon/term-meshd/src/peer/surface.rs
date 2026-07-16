//! Host-side surfaces backed by real PTYs (Phase 2.3B).
//!
//! A `PtySurface` wraps a forked child attached to a PTY master fd.
//! PTY output is fan-out to all attached clients via `tokio::broadcast`;
//! client input goes to the master via blocking `write(2)`.
//!
//! `PtyManager` owns the registry of live surfaces. For Phase 2.3B-a
//! we eagerly spawn a single default surface running `$SHELL -l`, with
//! a stable surface_id so clients can list + attach deterministically.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::os::unix::io::{AsRawFd, RawFd};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use peer_proto::v1::SurfaceInfo;
use tokio::io::unix::AsyncFd;
use tokio::io::Interest;
use tokio::sync::{broadcast, Notify};

use super::pty;
use super::query_filter::{ModeEvent, QueryFilter};

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
/// Default bytes of recent PTY output replayed to a newly attached relay.
/// This covers the common "shell prompt printed before the SSH relay
/// attached" case without turning the daemon into an unbounded terminal
/// scrollback store. Overridable at startup via `TERMMESH_PEER_REPLAY_BYTES`
/// and at runtime via the `peer.replay_capacity` RPC / `tm-agent daemon
/// replay-capacity --set`.
const REPLAY_CAPACITY_DEFAULT_BYTES: usize = 1024 * 1024; // 1 MiB
/// Lower bound accepted for the replay capacity (env or RPC/CLI set).
const REPLAY_CAPACITY_MIN_BYTES: usize = 4 * 1024; // 4 KiB
/// Upper bound accepted for the replay capacity (env or RPC/CLI set).
const REPLAY_CAPACITY_MAX_BYTES: usize = 64 * 1024 * 1024; // 64 MiB

/// Process-wide replay buffer capacity, in bytes. Every `PtySurface`'s
/// `ReplayBuffer::push` reads this on each call, so a runtime change via
/// `set_replay_capacity` takes effect for all surfaces on their next PTY
/// write without needing to walk/trim existing buffers up front.
static REPLAY_CAPACITY: AtomicUsize = AtomicUsize::new(REPLAY_CAPACITY_DEFAULT_BYTES);

/// Parse a `TERMMESH_PEER_REPLAY_BYTES`-style value (plain byte count, no
/// suffix) and clamp it to `[REPLAY_CAPACITY_MIN_BYTES,
/// REPLAY_CAPACITY_MAX_BYTES]`. Returns `(clamped_value, was_clamped)` on
/// success. Split out of `init_replay_capacity_from_env` so it's testable
/// without touching process env vars.
fn parse_and_clamp_replay_bytes(raw: &str) -> Result<(usize, bool), String> {
    let n: usize = raw
        .trim()
        .parse()
        .map_err(|e| format!("not a byte count: {e}"))?;
    let clamped = n.clamp(REPLAY_CAPACITY_MIN_BYTES, REPLAY_CAPACITY_MAX_BYTES);
    Ok((clamped, clamped != n))
}

/// Read `TERMMESH_PEER_REPLAY_BYTES` and apply it to the process-wide replay
/// capacity. Called once at daemon startup. Unset keeps the compiled-in
/// default; unparsable or out-of-range values fall back to the default (resp.
/// clamp to range) with a `tracing::warn!`.
pub fn init_replay_capacity_from_env() {
    let Ok(raw) = std::env::var("TERMMESH_PEER_REPLAY_BYTES") else {
        return;
    };
    match parse_and_clamp_replay_bytes(&raw) {
        Ok((clamped, was_clamped)) => {
            if was_clamped {
                tracing::warn!(
                    "TERMMESH_PEER_REPLAY_BYTES={raw:?} out of range [{REPLAY_CAPACITY_MIN_BYTES}, {REPLAY_CAPACITY_MAX_BYTES}], clamped to {clamped}"
                );
            }
            REPLAY_CAPACITY.store(clamped, Ordering::Relaxed);
        }
        Err(e) => {
            tracing::warn!(
                "TERMMESH_PEER_REPLAY_BYTES={raw:?} invalid ({e}), using default {REPLAY_CAPACITY_DEFAULT_BYTES}"
            );
        }
    }
}

/// Current replay buffer capacity, in bytes.
pub fn replay_capacity() -> usize {
    REPLAY_CAPACITY.load(Ordering::Relaxed)
}

/// Set the replay buffer capacity at runtime. Rejects values outside
/// `[REPLAY_CAPACITY_MIN_BYTES, REPLAY_CAPACITY_MAX_BYTES]` with an error
/// message instead of silently clamping, since this is an explicit
/// user-triggered action (RPC/CLI) rather than a background env read.
/// Returns `(old, new)` on success.
pub fn set_replay_capacity(bytes: usize) -> Result<(usize, usize), String> {
    if !(REPLAY_CAPACITY_MIN_BYTES..=REPLAY_CAPACITY_MAX_BYTES).contains(&bytes) {
        return Err(format!(
            "replay capacity must be between {REPLAY_CAPACITY_MIN_BYTES} and {REPLAY_CAPACITY_MAX_BYTES} bytes (got {bytes})"
        ));
    }
    let old = REPLAY_CAPACITY.swap(bytes, Ordering::Relaxed);
    Ok((old, bytes))
}

#[derive(Clone, Debug)]
pub struct PtyChunk {
    pub seq: u64,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Default)]
struct ReplayBuffer {
    chunks: VecDeque<PtyChunk>,
    bytes: usize,
}

impl ReplayBuffer {
    fn push(&mut self, chunk: PtyChunk) {
        if chunk.bytes.is_empty() {
            return;
        }
        self.bytes += chunk.bytes.len();
        self.chunks.push_back(chunk);
        // Read the process-wide capacity on every push (not cached) so a
        // runtime `set_replay_capacity` call takes effect immediately for
        // every surface's next write, without needing to walk and trim
        // existing buffers up front.
        let capacity = replay_capacity();
        while self.bytes > capacity {
            let Some(front) = self.chunks.pop_front() else {
                break;
            };
            self.bytes = self.bytes.saturating_sub(front.bytes.len());
        }
    }

    fn snapshot(&self) -> Vec<PtyChunk> {
        self.chunks.iter().cloned().collect()
    }
}

pub struct PtySurface {
    pub surface_id: Vec<u8>,
    pub title: String,
    pub workspace_name: String,
    pub cols: AtomicU32,
    pub rows: AtomicU32,
    /// Directory the child was spawned in (absolute path when resolvable).
    pub cwd: String,
    /// Git branch of `cwd` at spawn time; empty when cwd is not in a repo.
    pub branch: String,
    /// The authoritative broadcast sender. Subscribers are created via
    /// `.subscribe()`; the reader task owns a cloned sender for fan-out.
    pub broadcast_tx: broadcast::Sender<PtyChunk>,
    /// Set true when the PTY reader has observed EOF or the child died.
    /// Subscribers should detach when this flips.
    pub dead: AtomicBool,
    /// Notified when `dead` flips; lets relay tasks exit promptly without
    /// polling the flag.
    pub dead_notify: Notify,
    /// Monotonic byte offset for PTY chunks. Used only to de-duplicate replay
    /// bytes against live broadcast bytes at attach time.
    byte_seq: AtomicU64,
    replay: Mutex<ReplayBuffer>,
    /// DEC private (mouse-tracking) modes currently enabled on this PTY,
    /// mirrored from DECSET/DECRST bytes observed by the reader loop.
    /// Exists for attach-time mode replay: a relay that attaches after the
    /// PTY already toggled mouse reporting on needs to be told so too.
    modes: Mutex<BTreeSet<u16>>,
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
        cwd: Option<&str>,
    ) -> std::io::Result<Arc<Self>> {
        let child = pty::spawn(command, args, cols, rows, cwd)?;
        pty::set_nonblocking(child.master_fd)?;
        let (tx, _rx) = broadcast::channel::<PtyChunk>(BROADCAST_CAPACITY);

        let resolved_cwd = cwd.map(|c| c.to_string()).unwrap_or_else(|| {
            std::env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default()
        });
        let branch = resolve_git_branch(&resolved_cwd);

        let surface = Arc::new(PtySurface {
            surface_id: surface_id.clone(),
            title,
            workspace_name: "peer-host".into(),
            cols: AtomicU32::new(cols as u32),
            rows: AtomicU32::new(rows as u32),
            cwd: resolved_cwd,
            branch,
            broadcast_tx: tx.clone(),
            dead: AtomicBool::new(false),
            dead_notify: Notify::new(),
            byte_seq: AtomicU64::new(0),
            replay: Mutex::new(ReplayBuffer::default()),
            modes: Mutex::new(BTreeSet::new()),
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
            let async_fd =
                match AsyncFd::with_interest(BorrowedMasterFd(master_fd), Interest::READABLE) {
                    Ok(fd) => fd,
                    Err(e) => {
                        tracing::error!("AsyncFd registration failed: {e}");
                        reader_surface.dead.store(true, Ordering::Release);
                        reader_surface.dead_notify.notify_waiters();
                        return;
                    }
                };

            let mut buf = vec![0u8; READ_BUF_SIZE];
            let mut filter = QueryFilter::default();
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
                        libc::read(inner.as_raw_fd(), buf.as_mut_ptr() as *mut _, buf.len())
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
                        let (bytes, responses, mode_events) = filter.process(&buf[..n]);
                        if !responses.is_empty() {
                            // Synthesised reply to a terminal query
                            // (DA1/DA2/DSR/OSC 10·11). Write back to the
                            // PTY master so the originating program sees
                            // it on stdin without a relay round trip.
                            if let Err(e) = pty::write_all(master_fd, &responses) {
                                tracing::warn!(
                                    "query reply write failed on surface {:?}: {e}",
                                    hex_short(&reader_surface.surface_id)
                                );
                            }
                        }
                        if !mode_events.is_empty() {
                            // Only take the lock when a mode actually
                            // transitioned — most PTY output carries no
                            // DECSET/DECRST, so the hot path stays lock-free.
                            if let Ok(mut modes) = reader_surface.modes.lock() {
                                for event in mode_events {
                                    match event {
                                        ModeEvent::Set(mode) => {
                                            modes.insert(mode);
                                        }
                                        ModeEvent::Reset(mode) => {
                                            modes.remove(&mode);
                                        }
                                    }
                                }
                            }
                        }
                        if bytes.is_empty() {
                            continue;
                        }
                        let seq = reader_surface
                            .byte_seq
                            .fetch_add(bytes.len() as u64, Ordering::Relaxed);
                        let chunk = PtyChunk { seq, bytes };
                        if let Ok(mut replay) = reader_surface.replay.lock() {
                            replay.push(chunk.clone());
                        }
                        // Err only means "no subscribers", which is fine.
                        let _ = tx.send(chunk);
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

    /// Ask the child to exit now (SIGHUP, what it would get on a real
    /// terminal hangup). fd/reap cleanup still happens in `Drop`; this
    /// only decouples "the shell dies" from "the last viewer detaches".
    ///
    /// No-ops once `dead` is already true. The reader loop's
    /// `child_has_exited` check reaps the child via `waitpid(WNOHANG)`
    /// independently of `Drop` (on EIO, to disambiguate a real exit from
    /// the fork/exec EIO glitch) — well before `PtyManager::remove()`
    /// might call this. Signalling a pid after it's been reaped risks the
    /// OS having recycled it to an unrelated process under the same uid;
    /// `dead` is the only signal we have that the reap may have already
    /// happened, so treat it as authoritative here.
    pub fn hangup(&self) {
        if self.dead.load(Ordering::Acquire) {
            return;
        }
        // Safety: signalling a child pid we spawned and still own.
        unsafe {
            libc::kill(self.pid, libc::SIGHUP);
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<PtyChunk> {
        self.broadcast_tx.subscribe()
    }

    pub fn replay_snapshot(&self) -> Vec<PtyChunk> {
        self.replay
            .lock()
            .map(|replay| replay.snapshot())
            .unwrap_or_default()
    }

    /// Serializes currently-active tracked modes (mouse-tracking DECSET) as
    /// `ESC[?{mode}h` sequences in ascending numeric order — free thanks to
    /// `BTreeSet`'s ordering. Used for attach-time mode replay so a relay
    /// that attaches after the PTY already toggled a mode on isn't left
    /// out of sync. Empty when no tracked mode is currently active.
    pub fn mode_replay_bytes(&self) -> Vec<u8> {
        let modes = match self.modes.lock() {
            Ok(modes) => modes,
            Err(_) => return Vec::new(),
        };
        let mut out = Vec::with_capacity(modes.len() * 8);
        for mode in modes.iter() {
            out.extend_from_slice(format!("\x1B[?{mode}h").as_bytes());
        }
        out
    }

    pub fn write_all(&self, bytes: &[u8]) -> std::io::Result<()> {
        pty::write_all(self.master_fd, bytes)
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
            cwd: self.cwd.clone(),
            branch: self.branch.clone(),
        }
    }
}

/// Best-effort current-branch lookup via `git2`. Returns empty string when
/// `cwd` is not inside a git repo, the repo is in detached-HEAD state, or
/// any other error occurs — never panics or propagates.
fn resolve_git_branch(cwd: &str) -> String {
    let Ok(repo) = git2::Repository::discover(cwd) else {
        return String::new();
    };
    let Ok(head) = repo.head() else {
        return String::new();
    };
    head.shorthand().map(String::from).unwrap_or_default()
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
    /// Child's working directory before exec. `None` inherits the daemon's
    /// current dir at spawn time.
    pub cwd: Option<String>,
}

pub struct PtyManager {
    surfaces: RwLock<HashMap<Vec<u8>, Arc<PtySurface>>>,
    /// Registered "how to respawn this surface" specs keyed by surface_id.
    /// `insert_surface` (test-only path) does not populate this; production
    /// surfaces registered via `spawn_default` do.
    specs: RwLock<HashMap<Vec<u8>, SpawnSpec>>,
    /// Surface ids whose spec must NOT survive `remove()` — split/new-tab
    /// panes registered via `register_and_spawn_ephemeral`. Declared
    /// surfaces (`TERMMESH_PEER_SURFACES`, via the plain `register_and_spawn`)
    /// are the ones meant to come back after a restart; an ephemeral pane
    /// that was just closed must not be resurrectable by a raw
    /// `AttachSurface` for the same id while the daemon keeps running.
    ephemeral_specs: RwLock<std::collections::HashSet<Vec<u8>>>,
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

/// A shell candidate is usable when it is an absolute path to an
/// executable regular file whose name isn't a deliberate login blocker.
/// The blockers matter on servers: a systemd unit often has no SHELL at
/// all, and service accounts carry /usr/sbin/nologin or /bin/false —
/// spawning either gives an instantly-exiting pane that looks like a
/// daemon bug.
fn is_usable_shell(path: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    if !path.starts_with('/') {
        return false;
    }
    let base = path.rsplit('/').next().unwrap_or("");
    if matches!(base, "nologin" | "false") {
        return false;
    }
    match std::fs::metadata(path) {
        Ok(md) => md.is_file() && md.permissions().mode() & 0o111 != 0,
        Err(_) => false,
    }
}

/// Pick the login shell for a new pane: the candidate (normally `$SHELL`)
/// when usable, else `/bin/bash`, else `/bin/sh`. The final `/bin/sh`
/// fallthrough is unconditional — POSIX guarantees its presence, and a
/// broken pane beats a spawn that never happens.
pub(crate) fn resolve_login_shell(candidate: Option<&str>) -> String {
    if let Some(c) = candidate {
        if is_usable_shell(c) {
            return c.to_string();
        }
    }
    if is_usable_shell("/bin/bash") {
        return "/bin/bash".to_string();
    }
    "/bin/sh".to_string()
}

/// `<shell> -l` command line for a new pane, shared by the startup
/// fallback surface and split/new-tab spawns.
pub(crate) fn login_shell_cmd() -> String {
    let shell = resolve_login_shell(std::env::var("SHELL").ok().as_deref());
    format!("{shell} -l")
}

fn default_shell_cmd() -> String {
    login_shell_cmd()
}

impl PtyManager {
    pub fn new() -> Self {
        Self {
            surfaces: RwLock::new(HashMap::new()),
            specs: RwLock::new(HashMap::new()),
            ephemeral_specs: RwLock::new(std::collections::HashSet::new()),
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
                cwd: None,
            };
            self.register_and_spawn(surface_id, spec);
        }
    }

    /// Register a respawn spec under `surface_id` and spawn its first
    /// instance. Errors are logged; the server runs on regardless. The
    /// spec (and therefore respawn-via-`get_or_respawn`) survives a
    /// `remove()` — this is the declared-surface path
    /// (`TERMMESH_PEER_SURFACES`), where "closed" means "gone until the
    /// next restart brings the config back", not "gone forever".
    pub fn register_and_spawn(&self, surface_id: Vec<u8>, spec: SpawnSpec) {
        self.register_and_spawn_inner(surface_id, spec, false);
    }

    /// Same as `register_and_spawn`, but the spec is dropped along with
    /// the surface on `remove()` (explicit `ClosePane` or the ephemeral
    /// dead-watcher) — so a `split`/`new_tab`-spawned pane cannot be
    /// resurrected by a raw `AttachSurface` for the same id after it was
    /// closed. Use for panes created outside `TERMMESH_PEER_SURFACES`.
    pub fn register_and_spawn_ephemeral(&self, surface_id: Vec<u8>, spec: SpawnSpec) {
        self.register_and_spawn_inner(surface_id, spec, true);
    }

    fn register_and_spawn_inner(&self, surface_id: Vec<u8>, spec: SpawnSpec, ephemeral: bool) {
        match spawn_from_spec(&surface_id, &spec) {
            Ok(surface) => {
                self.surfaces
                    .write()
                    .unwrap()
                    .insert(surface_id.clone(), surface);
                self.specs.write().unwrap().insert(surface_id.clone(), spec);
                if ephemeral {
                    self.ephemeral_specs.write().unwrap().insert(surface_id);
                }
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

    /// Close a pane's surface: hang the child up and drop it from the
    /// roster. The respawn spec is kept for a *declared* surface (closing
    /// it removes it for this daemon lifetime only; a restart brings the
    /// `TERMMESH_PEER_SURFACES` set back) but purged for an *ephemeral*
    /// one (`register_and_spawn_ephemeral`) — otherwise a raw
    /// `AttachSurface` for the same id would resurrect a supposedly-closed
    /// split/new-tab pane, invisible in the layout tree, indefinitely.
    ///
    /// The SIGHUP is explicit rather than left to `Drop` because attach
    /// relays hold `Arc` clones: waiting for the last clone would keep
    /// the shell running until every viewer detaches, which is not what
    /// "close" means.
    pub fn remove(&self, surface_id: &[u8]) -> bool {
        let removed = self.surfaces.write().unwrap().remove(surface_id);
        if self.ephemeral_specs.write().unwrap().remove(surface_id) {
            self.specs.write().unwrap().remove(surface_id);
        }
        match removed {
            Some(surface) => {
                surface.hangup();
                true
            }
            None => false,
        }
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
                tracing::info!("respawned surface after exit: {}", hex_short(surface_id));
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
        spec.cwd.as_deref(),
    )
}

fn hex_short(bytes: &[u8]) -> String {
    let n = bytes.len().min(4);
    bytes[..n].iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `/bin/cat` is a lightweight, deterministic long-lived child — same
    /// pattern used by `peer::server`'s `cat_manager()` test helper. We
    /// only need a real `PtySurface` to exercise `modes`/`mode_replay_bytes`;
    /// no PTY I/O is involved in these tests.
    fn cat_surface() -> Arc<PtySurface> {
        PtySurface::spawn(
            surface_id_from_name("mode-replay-test"),
            "cat".into(),
            "/bin/cat",
            &[],
            80,
            24,
            None,
        )
        .expect("spawn /bin/cat")
    }

    #[tokio::test]
    async fn mode_replay_bytes_serializes_ascending() {
        let surface = cat_surface();
        {
            // Insert out of numeric order to prove BTreeSet ordering,
            // not insertion order, drives the serialized sequence.
            let mut modes = surface.modes.lock().unwrap();
            modes.insert(1006);
            modes.insert(1002);
        }
        assert_eq!(
            surface.mode_replay_bytes(),
            b"\x1B[?1002h\x1B[?1006h".to_vec()
        );
    }

    #[tokio::test]
    async fn mode_replay_bytes_empty_after_reset() {
        let surface = cat_surface();
        {
            let mut modes = surface.modes.lock().unwrap();
            modes.insert(1000);
            modes.remove(&1000);
        }
        assert!(surface.mode_replay_bytes().is_empty());
    }

    /// F3 regression: once `dead` is true, `hangup()` must not signal the
    /// pid at all (it may already be reaped and recycled). Proven
    /// behaviorally: mark a live /bin/cat surface dead (simulating the
    /// reader loop having already reaped it via `child_has_exited`), call
    /// `hangup()`, then confirm the process is still alive and echoing —
    /// if the (incorrect) SIGHUP had actually been sent, cat's default
    /// disposition terminates it and the echo would never arrive.
    #[tokio::test]
    async fn hangup_noops_once_already_dead() {
        let surface = cat_surface();
        surface.dead.store(true, Ordering::Release);
        surface.hangup();

        let mut rx = surface.subscribe();
        surface.write_all(b"still-alive\n").expect("write to cat");
        let result = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                let chunk = rx.recv().await.expect("broadcast channel");
                if chunk.bytes.windows(11).any(|w| w == b"still-alive") {
                    return;
                }
            }
        })
        .await;
        assert!(result.is_ok(), "cat did not echo — hangup() signalled it despite dead=true");
    }

    /// F6 regression: asserting a hardcoded "/bin/bash" result meant this
    /// test failed on exactly the minimal/musl environments (no bash)
    /// docs/peer-linux-host.md targets, where resolve_login_shell falling
    /// through to /bin/sh is the CORRECT behavior, not a bug. Assert the
    /// property instead: never the blocker itself, and always one of the
    /// two real fallback candidates.
    #[test]
    fn login_shell_falls_back_past_blockers() {
        let assert_falls_back = |candidate: Option<&str>| {
            let result = resolve_login_shell(candidate);
            assert_ne!(Some(result.as_str()), candidate, "must not echo back a blocked candidate");
            assert!(
                matches!(result.as_str(), "/bin/bash" | "/bin/sh"),
                "fallback must be /bin/bash or /bin/sh, got {result:?}"
            );
        };
        // Deliberate login blockers (F: systemd service accounts).
        assert_falls_back(Some("/bin/false"));
        assert_falls_back(Some("/usr/sbin/nologin"));
        // Nonexistent / relative / empty candidates.
        assert_falls_back(Some("/no/such/shell"));
        assert_falls_back(Some("zsh"));
        assert_falls_back(Some(""));
        // No candidate at all (SHELL unset under systemd).
        assert_falls_back(None);
        // A usable candidate wins as-is — the one case with an exact
        // expected value, since /bin/sh is universally present.
        assert_eq!(resolve_login_shell(Some("/bin/sh")), "/bin/sh");
    }

    // ── Replay capacity (t11: TERMMESH_PEER_REPLAY_BYTES env + RPC/CLI) ──

    #[test]
    fn parse_replay_bytes_accepts_plain_integer() {
        assert_eq!(parse_and_clamp_replay_bytes("262144"), Ok((262144, false)));
        // Leading/trailing whitespace (e.g. from a shell env file) is trimmed.
        assert_eq!(parse_and_clamp_replay_bytes(" 262144 \n"), Ok((262144, false)));
    }

    #[test]
    fn parse_replay_bytes_rejects_garbage() {
        // No suffix support at this layer — "2mb"/"256kb" are the CLI's job
        // (it converts to a plain byte count before calling the RPC).
        assert!(parse_and_clamp_replay_bytes("2mb").is_err());
        assert!(parse_and_clamp_replay_bytes("not-a-number").is_err());
        assert!(parse_and_clamp_replay_bytes("").is_err());
        assert!(parse_and_clamp_replay_bytes("-1").is_err());
    }

    #[test]
    fn parse_replay_bytes_clamps_out_of_range() {
        let (low, was_clamped) = parse_and_clamp_replay_bytes("1").unwrap();
        assert_eq!(low, REPLAY_CAPACITY_MIN_BYTES);
        assert!(was_clamped);

        let (high, was_clamped) = parse_and_clamp_replay_bytes("999999999999").unwrap();
        assert_eq!(high, REPLAY_CAPACITY_MAX_BYTES);
        assert!(was_clamped);
    }

    #[test]
    fn parse_replay_bytes_in_range_not_clamped() {
        let mid = (REPLAY_CAPACITY_MIN_BYTES + REPLAY_CAPACITY_MAX_BYTES) / 2;
        let (v, was_clamped) = parse_and_clamp_replay_bytes(&mid.to_string()).unwrap();
        assert_eq!(v, mid);
        assert!(!was_clamped);
    }

    #[test]
    fn set_replay_capacity_rejects_out_of_range() {
        assert!(set_replay_capacity(REPLAY_CAPACITY_MIN_BYTES - 1).is_err());
        assert!(set_replay_capacity(REPLAY_CAPACITY_MAX_BYTES + 1).is_err());
    }

    #[test]
    fn set_replay_capacity_accepts_boundaries_and_reports_old_new() {
        let original = replay_capacity();
        let (old, new) = set_replay_capacity(REPLAY_CAPACITY_MIN_BYTES).unwrap();
        assert_eq!(old, original);
        assert_eq!(new, REPLAY_CAPACITY_MIN_BYTES);
        assert_eq!(replay_capacity(), REPLAY_CAPACITY_MIN_BYTES);
        // Restore — REPLAY_CAPACITY is process-wide, shared with other tests.
        set_replay_capacity(original).unwrap();
    }

    /// Proves `ReplayBuffer::push`'s eviction loop reads the *live* static
    /// on every call rather than a value baked in at buffer-creation time —
    /// the whole point of moving off the old compile-time `const`.
    #[test]
    fn replay_buffer_eviction_follows_runtime_capacity_change() {
        let original = replay_capacity();
        let (_old, new) = set_replay_capacity(REPLAY_CAPACITY_MIN_BYTES).unwrap();
        assert_eq!(new, REPLAY_CAPACITY_MIN_BYTES);

        let mut buf = ReplayBuffer::default();
        // 8 chunks of 1024 bytes each; MIN (4096) only fits the last 4.
        for seq in 0..8u64 {
            buf.push(PtyChunk { seq, bytes: vec![0u8; 1024] });
        }
        assert!(
            buf.bytes <= REPLAY_CAPACITY_MIN_BYTES,
            "expected eviction down to the lowered capacity, got {} bytes",
            buf.bytes
        );
        let kept: Vec<u64> = buf.snapshot().iter().map(|c| c.seq).collect();
        assert_eq!(kept, vec![4, 5, 6, 7], "oldest chunks must be evicted first (FIFO)");

        set_replay_capacity(original).unwrap();
    }
}
