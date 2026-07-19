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
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock, Weak};

use peer_proto::v1::SurfaceInfo;
use sha2::{Digest, Sha256};
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

/// Grace window a forced terminate (`shutdown_forcibly`) gives a child to
/// honor SIGHUP and exit on its own before escalating to SIGKILL: poll
/// `FORCE_KILL_GRACE_POLLS` times, `FORCE_KILL_GRACE_INTERVAL` apart
/// (≈100 ms total worst case). A cooperative shell exits on the first poll;
/// only a child that ignores/outlives SIGHUP (observed: macOS forkpty
/// session leaders) pays the full window before it is force-killed.
const FORCE_KILL_GRACE_POLLS: u32 = 10;
const FORCE_KILL_GRACE_INTERVAL: std::time::Duration = std::time::Duration::from_millis(10);

/// Bound on the post-SIGKILL reap. Generous next to the pre-kill grace window
/// (a SIGKILLed child normally goes on the first poll) but finite, because the
/// teardown path must never be able to block its caller forever.
const REAP_AFTER_KILL_POLLS: u32 = 50;
const REAP_AFTER_KILL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(20);

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
    child: Mutex<ChildLifecycle>,
    signal_owners: AtomicUsize,
    reap_owners: AtomicUsize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ChildState {
    Running,
    Signaled,
    Reaped,
    /// SIGKILL was delivered but the child could not be reaped within the
    /// teardown's bounded window — it is stuck mid-exit in the kernel.
    ///
    /// Terminal, and deliberately NOT `Reaped`: the pid was never waited on,
    /// so it may still be recycled, and every signalling path must therefore
    /// leave it alone from here on. Treated as gone for liveness, because a
    /// SIGKILLed process never comes back.
    Abandoned,
}

#[derive(Debug)]
struct ChildLifecycle {
    pid: libc::pid_t,
    state: ChildState,
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
            child: Mutex::new(ChildLifecycle {
                pid: child.pid,
                state: ChildState::Running,
            }),
            signal_owners: AtomicUsize::new(0),
            reap_owners: AtomicUsize::new(0),
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
                        reader_surface.hangup();
                        reader_surface.mark_dead();
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
                                if reader_surface.child_has_exited() {
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
            if !reader_surface.child_has_exited() {
                reader_surface.hangup();
            }
            reader_surface.mark_dead();
        });

        Ok(surface)
    }

    /// Ask the child to exit now (SIGHUP, what it would get on a real
    /// terminal hangup). fd/reap cleanup still happens in `Drop`; this
    /// only decouples "the shell dies" from "the last viewer detaches".
    ///
    /// Signal ownership and waitpid/reap ownership share one mutex state.
    /// Once another path observes/reaps exit, no later caller can signal the
    /// numeric pid after the OS has made it reusable.
    pub fn hangup(&self) {
        let Ok(mut child) = self.child.lock() else {
            return;
        };
        if child.state != ChildState::Running {
            return;
        }
        // Safety: the mutex proves this child has not been reaped, so its pid
        // cannot yet have been recycled to an unrelated process.
        if unsafe { libc::kill(child.pid, libc::SIGHUP) } == 0 {
            self.signal_owners.fetch_add(1, Ordering::Relaxed);
        }
        child.state = ChildState::Signaled;
    }

    /// Destructive teardown for an explicit `terminate`: SIGHUP first (a
    /// shell still gets the signal a real hangup delivers, so its EXIT trap
    /// runs), then, if the child is still alive after a brief grace window,
    /// SIGKILL and reap. Unlike `hangup()`, this GUARANTEES the process is
    /// gone before it returns.
    ///
    /// `hangup()` alone is not enough for a terminate: it relies on the
    /// child honoring SIGHUP so the reader hits EOF and the reader's Arc →
    /// `Drop` → reap chain unwinds. A child that ignores or outlives SIGHUP
    /// (a macOS forkpty session leader was observed surviving it) then leaks
    /// as an orphan while the still-blocked reader keeps the surface Arc
    /// alive forever — so a terminate that reported success left a live
    /// process behind. SIGKILL cannot be caught or ignored, so escalating to
    /// it is the platform-independent guarantee (the same
    /// SIGHUP-then-SIGKILL shape the daemon's own shutdown fix uses).
    ///
    /// The lifecycle lock is held for the whole grace window on purpose: it
    /// is what proves the pid has not been reaped, so no concurrent path can
    /// reap-and-recycle it out from under the SIGKILL. The window is bounded
    /// (`FORCE_KILL_GRACE_POLLS` × `FORCE_KILL_GRACE_INTERVAL`) and only the
    /// terminate path takes it, so contention is a non-issue.
    pub fn shutdown_forcibly(&self) {
        let Ok(mut child) = self.child.lock() else {
            return;
        };
        if matches!(child.state, ChildState::Reaped | ChildState::Abandoned) {
            return;
        }
        if child.state == ChildState::Running {
            // Safety: the mutex proves this child has not been reaped, so its
            // pid cannot yet have been recycled to an unrelated process.
            if unsafe { libc::kill(child.pid, libc::SIGHUP) } == 0 {
                self.signal_owners.fetch_add(1, Ordering::Relaxed);
            }
            child.state = ChildState::Signaled;
        }
        for _ in 0..FORCE_KILL_GRACE_POLLS {
            if Self::observe_exit_locked(&mut child, &self.reap_owners) {
                return;
            }
            std::thread::sleep(FORCE_KILL_GRACE_INTERVAL);
        }
        // Still running after the grace window — force it.
        // Safety: still holding the lifecycle lock, so the pid is not yet
        // reaped/recycled.
        unsafe {
            libc::kill(child.pid, libc::SIGKILL);
        }
        Self::reap_after_kill_locked(&mut child, &self.reap_owners);
    }

    /// Reap the child after a SIGKILL, giving up after a bounded window.
    ///
    /// This used to be a plain blocking `waitpid` (no `WNOHANG`), on the
    /// premise that a SIGKILLed child exits promptly. It does not always: a
    /// PTY child stuck mid-exit in the kernel — output buffered on a master
    /// nobody is draining — stays unreapable for as long as the drain is
    /// starved. `shutdown_forcibly` runs on the caller's thread, so on a
    /// current-thread runtime that caller can BE the drain, and the wait then
    /// never ends. `remove()` is the pane-close and workspace-delete path, so
    /// that hung the daemon, not just a test.
    ///
    /// Polling with `WNOHANG` against a deadline keeps the pid-recycling
    /// guarantee where it matters and drops only the unbounded wait: either
    /// the child is reaped here, or it is marked [`ChildState::Abandoned`] and
    /// no path signals that pid again. SIGKILL is already delivered, so the
    /// process is gone as soon as the kernel lets it finish; init reaps it.
    fn reap_after_kill_locked(child: &mut ChildLifecycle, reap_owners: &AtomicUsize) {
        if matches!(child.state, ChildState::Reaped | ChildState::Abandoned) {
            return;
        }
        for _ in 0..REAP_AFTER_KILL_POLLS {
            if Self::observe_exit_locked(child, reap_owners) {
                return;
            }
            std::thread::sleep(REAP_AFTER_KILL_INTERVAL);
        }
        tracing::warn!(
            pid = child.pid,
            "SIGKILLed child not reapable within the teardown window; abandoning its pid"
        );
        child.state = ChildState::Abandoned;
    }

    fn child_has_exited(&self) -> bool {
        let Ok(mut child) = self.child.lock() else {
            self.mark_dead();
            return true;
        };
        let exited = Self::observe_exit_locked(&mut child, &self.reap_owners);
        if exited {
            self.mark_dead();
        }
        drop(child);
        exited
    }

    fn observe_exit_locked(child: &mut ChildLifecycle, reap_owners: &AtomicUsize) -> bool {
        // Abandoned is terminal too: SIGKILL was delivered, so the child is
        // never coming back, and its pid must not be waited on again.
        if matches!(child.state, ChildState::Reaped | ChildState::Abandoned) {
            return true;
        }
        loop {
            let mut status = 0;
            // Safety: all waitpid calls for this surface are serialized by
            // `child`; no second owner can reap or signal concurrently.
            let result = unsafe { libc::waitpid(child.pid, &mut status, libc::WNOHANG) };
            if result == child.pid
                || (result < 0
                    && std::io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD))
            {
                child.state = ChildState::Reaped;
                reap_owners.fetch_add(1, Ordering::Relaxed);
                return true;
            }
            if result == 0 {
                return false;
            }
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                return false;
            }
        }
    }

    fn pid(&self) -> libc::pid_t {
        self.child.lock().map(|child| child.pid).unwrap_or(-1)
    }

    fn is_live(&self) -> bool {
        !self.dead.load(Ordering::Acquire) && !self.child_has_exited()
    }

    fn mark_dead(&self) {
        if !self.dead.swap(true, Ordering::AcqRel) {
            self.dead_notify.notify_waiters();
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

    /// True when the shell has handed the terminal's foreground process
    /// group to a child — i.e. a command is running — and false when the
    /// shell sits at its prompt (idle) or the child is gone.
    ///
    /// `forkpty` makes our child a session leader, so its pgid == its pid;
    /// a foreground command runs in a different pgrp that the shell
    /// `tcsetpgrp`s onto the master. So `tcgetpgrp(master) != shell_pid`
    /// means "busy". One syscall, no stored state, evaluated at snapshot
    /// time only (ListWorkspaces / layout push) — never polled.
    pub fn is_busy(&self) -> bool {
        let shell_pgid = match self.child.lock() {
            Ok(child) if child.state == ChildState::Running => child.pid,
            _ => return false,
        };
        let fg = unsafe { libc::tcgetpgrp(self.master_fd) };
        fg > 0 && fg != shell_pgid
    }

    pub fn info(&self) -> SurfaceInfo {
        SurfaceInfo {
            surface_id: self.surface_id.clone(),
            workspace_name: self.workspace_name.clone(),
            title: self.title.clone(),
            cols: self.cols.load(Ordering::Relaxed),
            rows: self.rows.load(Ordering::Relaxed),
            surface_type: "terminal".into(),
            attachable: self.is_live(),
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
        // Reader owns an Arc, so normal Drop follows reader exit/reap. Runtime
        // shutdown can abort the reader first; in that case signal once while
        // holding the same lifecycle lock, close the fd, and attempt WNOHANG.
        if let Ok(child) = self.child.get_mut() {
            if child.state == ChildState::Running {
                if unsafe { libc::kill(child.pid, libc::SIGHUP) } == 0 {
                    self.signal_owners.fetch_add(1, Ordering::Relaxed);
                }
                child.state = ChildState::Signaled;
            }
            let _ = Self::observe_exit_locked(child, &self.reap_owners);
        }
        // Safety: this surface uniquely owns the PTY master fd at Drop.
        unsafe {
            libc::close(self.master_fd);
        }
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

/// Deterministic desired state for an ensured surface. The logical `key` is
/// deliberately not part of this value: it selects the stable surface id,
/// while this structure answers whether an existing surface is compatible.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SurfaceSpec {
    pub cwd: String,
    pub executable: String,
    pub args: Vec<String>,
    pub restart_policy: EnsureRestartPolicy,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnsureRestartPolicy {
    Never,
    OnDaemonRestart,
}

impl EnsureRestartPolicy {
    fn canonical_byte(self) -> u8 {
        match self {
            Self::Never => 0,
            Self::OnDaemonRestart => 1,
        }
    }
}

impl SurfaceSpec {
    /// Hash a length-delimited, versioned encoding instead of JSON or joined
    /// strings. This is stable across process runs and cannot confuse field or
    /// argument boundaries (`["a", "bc"]` and `["ab", "c"]` differ).
    pub fn canonical_hash(&self) -> [u8; 32] {
        fn field(hasher: &mut Sha256, bytes: &[u8]) {
            hasher.update((bytes.len() as u64).to_be_bytes());
            hasher.update(bytes);
        }

        let mut hasher = Sha256::new();
        hasher.update(b"term-mesh.surface-spec.v1\0");
        field(&mut hasher, self.cwd.as_bytes());
        field(&mut hasher, self.executable.as_bytes());
        hasher.update((self.args.len() as u64).to_be_bytes());
        for arg in &self.args {
            field(&mut hasher, arg.as_bytes());
        }
        hasher.update([self.restart_policy.canonical_byte()]);
        hasher.finalize().into()
    }

    fn spawn_spec(&self, key: &str) -> SpawnSpec {
        SpawnSpec {
            title: key.to_string(),
            command: self.executable.clone(),
            args: self.args.clone(),
            cols: 80,
            rows: 24,
            cwd: Some(self.cwd.clone()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnsureDisposition {
    Created,
    Reused,
    Recreated,
}

#[derive(Clone)]
pub struct EnsureOutcome {
    pub disposition: EnsureDisposition,
    pub surface: Arc<PtySurface>,
    pub surface_id: Vec<u8>,
    pub instance_id: Vec<u8>,
    pub generation: u64,
    pub pid: i64,
    pub spec_hash: [u8; 32],
}

#[derive(Debug)]
pub enum EnsureError {
    InvalidKey(&'static str),
    SpecConflict {
        surface_id: Vec<u8>,
        existing_spec_hash: [u8; 32],
        requested_spec_hash: [u8; 32],
    },
    NotRunning(Vec<u8>),
    Spawn(std::io::Error),
    Persistence(std::io::Error),
    Internal(&'static str),
}

impl std::fmt::Display for EnsureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidKey(reason) => write!(f, "INVALID_KEY: {reason}"),
            Self::SpecConflict { .. } => f.write_str("SPEC_CONFLICT"),
            Self::NotRunning(_) => f.write_str("SURFACE_NOT_RUNNING"),
            Self::Spawn(error) => write!(f, "{error}"),
            Self::Persistence(error) => write!(f, "PERSISTENCE_ERROR: {error}"),
            Self::Internal(message) => write!(f, "INTERNAL: {message}"),
        }
    }
}

impl std::error::Error for EnsureError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Spawn(error) | Self::Persistence(error) => Some(error),
            _ => None,
        }
    }
}

#[derive(Clone)]
struct EnsuredRecord {
    key: String,
    spec_hash: [u8; 32],
    instance_id: Vec<u8>,
    generation: u64,
    restored: bool,
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
    /// Desired-state metadata for surfaces created by `ensure`. Lifecycle
    /// persistence/registration is intentionally left to the next layer.
    ensured: RwLock<HashMap<Vec<u8>, EnsuredRecord>>,
    ensured_persist_path: RwLock<Option<PathBuf>>,
    ensured_persist_lock: Mutex<()>,
    /// All mutations for a surface id share one boundary. Weak entries plus
    /// identity-aware cleanup prevent invalid/one-shot keys growing this map.
    surface_reservations: Mutex<HashMap<Vec<u8>, Weak<Mutex<()>>>>,
    /// Set before `remove` waits for a reservation. An ensure that reaches the
    /// boundary after close intent is visible must never return a dying PID.
    closing: Mutex<HashMap<Vec<u8>, usize>>,
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
            ensured: RwLock::new(HashMap::new()),
            ensured_persist_path: RwLock::new(None),
            ensured_persist_lock: Mutex::new(()),
            surface_reservations: Mutex::new(HashMap::new()),
            closing: Mutex::new(HashMap::new()),
        }
    }

    fn surface_reservation(&self, surface_id: &[u8]) -> Result<Arc<Mutex<()>>, EnsureError> {
        let mut reservations = self
            .surface_reservations
            .lock()
            .map_err(|_| EnsureError::Internal("ensure reservation registry poisoned"))?;
        reservations.retain(|_, reservation| reservation.strong_count() > 0);
        if let Some(reservation) = reservations.get(surface_id).and_then(Weak::upgrade) {
            return Ok(reservation);
        }
        let reservation = Arc::new(Mutex::new(()));
        reservations.insert(surface_id.to_vec(), Arc::downgrade(&reservation));
        Ok(reservation)
    }

    fn release_surface_reservation(&self, surface_id: &[u8], reservation: &Arc<Mutex<()>>) {
        let Ok(mut reservations) = self.surface_reservations.lock() else {
            return;
        };
        let remove = reservations
            .get(surface_id)
            .and_then(Weak::upgrade)
            .is_some_and(|current| {
                Arc::ptr_eq(&current, reservation) && Arc::strong_count(reservation) == 2
            });
        if remove {
            reservations.remove(surface_id);
        }
    }

    fn is_closing(&self, surface_id: &[u8]) -> Result<bool, EnsureError> {
        self.closing
            .lock()
            .map(|closing| closing.get(surface_id).copied().unwrap_or(0) > 0)
            .map_err(|_| EnsureError::Internal("closing registry poisoned"))
    }

    fn begin_close(&self, surface_id: &[u8]) -> bool {
        let Ok(mut closing) = self.closing.lock() else {
            return false;
        };
        *closing.entry(surface_id.to_vec()).or_insert(0) += 1;
        true
    }

    fn end_close(&self, surface_id: &[u8]) {
        let Ok(mut closing) = self.closing.lock() else {
            return;
        };
        if let Some(count) = closing.get_mut(surface_id) {
            *count -= 1;
            if *count == 0 {
                closing.remove(surface_id);
            }
        }
    }

    fn validate_ensure_key(key: &str) -> Result<(), EnsureError> {
        if key.is_empty() {
            return Err(EnsureError::InvalidKey("key must not be empty"));
        }
        if key.len() > 256 {
            return Err(EnsureError::InvalidKey("key exceeds 256 UTF-8 bytes"));
        }
        Ok(())
    }

    /// Load the independent ensured-surface namespace. Production wires this
    /// once before accepting peers; tests pass an isolated path directly.
    pub fn set_ensured_persist_path(&self, path: PathBuf) {
        let _persist_guard = self.ensured_persist_lock.lock().unwrap();
        let records = super::persist::load_ensured_surfaces(&path);
        let mut ensured = self.ensured.write().unwrap();
        for record in records {
            ensured.entry(record.surface_id).or_insert(EnsuredRecord {
                key: record.key,
                spec_hash: record.spec_hash,
                instance_id: Vec::new(),
                generation: record.generation,
                restored: true,
            });
        }
        *self.ensured_persist_path.write().unwrap() = Some(path);
    }

    fn persist_ensured_locked(&self) -> std::io::Result<()> {
        let Some(path) = self.ensured_persist_path.read().unwrap().clone() else {
            return Ok(());
        };
        let records = self
            .ensured
            .read()
            .unwrap()
            .iter()
            .map(
                |(surface_id, record)| super::persist::PersistedEnsuredSurface {
                    key: record.key.clone(),
                    surface_id: surface_id.clone(),
                    spec_hash: record.spec_hash,
                    generation: record.generation,
                },
            )
            .collect::<Vec<_>>();
        super::persist::save_ensured_surfaces(&path, &records)
    }

    /// Create or reuse the one live process identified by `key`.
    ///
    /// The compatibility check happens while holding a key-local reservation
    /// and before any registry or process mutation. A different spec can
    /// therefore never replace the existing process as a side effect.
    pub fn ensure(&self, key: &str, spec: &SurfaceSpec) -> Result<EnsureOutcome, EnsureError> {
        Self::validate_ensure_key(key)?;
        let surface_id = surface_id_from_name(key);
        let requested_spec_hash = spec.canonical_hash();
        let reservation = self.surface_reservation(&surface_id)?;
        let result = {
            let _guard = reservation
                .lock()
                .map_err(|_| EnsureError::Internal("surface reservation poisoned"))?;
            self.ensure_locked(&surface_id, key, spec, requested_spec_hash)
        };
        self.release_surface_reservation(&surface_id, &reservation);
        result
    }

    fn ensure_locked(
        &self,
        surface_id: &[u8],
        key: &str,
        spec: &SurfaceSpec,
        requested_spec_hash: [u8; 32],
    ) -> Result<EnsureOutcome, EnsureError> {
        if self.is_closing(surface_id)? {
            return Err(EnsureError::NotRunning(surface_id.to_vec()));
        }

        // Bind the snapshot in its own scope. An `if let` directly over the
        // RwLock temporary extends the read guard through the whole branch,
        // deadlocking restored-record recreation when it later takes write().
        let existing_record = {
            let ensured = self
                .ensured
                .read()
                .map_err(|_| EnsureError::Internal("ensured registry poisoned"))?;
            ensured.get(surface_id).cloned()
        };
        if let Some(record) = existing_record {
            if record.spec_hash != requested_spec_hash {
                return Err(EnsureError::SpecConflict {
                    surface_id: surface_id.to_vec(),
                    existing_spec_hash: record.spec_hash,
                    requested_spec_hash,
                });
            }

            if !record.restored {
                let surface = self
                    .surfaces
                    .read()
                    .map_err(|_| EnsureError::Internal("surface registry poisoned"))?
                    .get(surface_id)
                    .cloned()
                    .ok_or_else(|| EnsureError::NotRunning(surface_id.to_vec()))?;
                if !surface.is_live() || self.is_closing(surface_id)? {
                    return Err(EnsureError::NotRunning(surface_id.to_vec()));
                }
                return Ok(EnsureOutcome {
                    disposition: EnsureDisposition::Reused,
                    pid: surface.pid() as i64,
                    surface,
                    surface_id: surface_id.to_vec(),
                    instance_id: record.instance_id,
                    generation: record.generation,
                    spec_hash: record.spec_hash,
                });
            }

            if spec.restart_policy == EnsureRestartPolicy::Never {
                return Err(EnsureError::NotRunning(surface_id.to_vec()));
            }
            if self
                .surfaces
                .read()
                .map_err(|_| EnsureError::Internal("surface registry poisoned"))?
                .contains_key(surface_id)
            {
                return Err(EnsureError::SpecConflict {
                    surface_id: surface_id.to_vec(),
                    existing_spec_hash: [0; 32],
                    requested_spec_hash,
                });
            }
            let surface =
                spawn_from_spec(surface_id, &spec.spawn_spec(key)).map_err(EnsureError::Spawn)?;
            let instance_id = uuid::Uuid::new_v4().as_bytes().to_vec();
            let generation = record
                .generation
                .checked_add(1)
                .ok_or(EnsureError::Internal("ensured generation exhausted"))?;
            let _persist_guard = self
                .ensured_persist_lock
                .lock()
                .map_err(|_| EnsureError::Internal("ensured persistence lock poisoned"))?;
            self.surfaces
                .write()
                .map_err(|_| EnsureError::Internal("surface registry poisoned"))?
                .insert(surface_id.to_vec(), surface.clone());
            self.ensured
                .write()
                .map_err(|_| EnsureError::Internal("ensured registry poisoned"))?
                .insert(
                    surface_id.to_vec(),
                    EnsuredRecord {
                        key: key.to_string(),
                        spec_hash: requested_spec_hash,
                        instance_id: instance_id.clone(),
                        generation,
                        restored: false,
                    },
                );
            if let Err(error) = self.persist_ensured_locked() {
                self.surfaces.write().unwrap().remove(surface_id);
                self.ensured
                    .write()
                    .unwrap()
                    .insert(surface_id.to_vec(), record);
                surface.hangup();
                return Err(EnsureError::Persistence(error));
            }
            return Ok(EnsureOutcome {
                disposition: EnsureDisposition::Recreated,
                pid: surface.pid() as i64,
                surface,
                surface_id: surface_id.to_vec(),
                instance_id,
                generation,
                spec_hash: requested_spec_hash,
            });
        }

        // A key-derived id already owned by a declared/ephemeral surface must
        // not be overwritten. Treat it as incompatible desired state.
        if self
            .surfaces
            .read()
            .map_err(|_| EnsureError::Internal("surface registry poisoned"))?
            .contains_key(surface_id)
        {
            return Err(EnsureError::SpecConflict {
                surface_id: surface_id.to_vec(),
                existing_spec_hash: [0; 32],
                requested_spec_hash,
            });
        }

        let surface =
            spawn_from_spec(surface_id, &spec.spawn_spec(key)).map_err(EnsureError::Spawn)?;
        let instance_id = uuid::Uuid::new_v4().as_bytes().to_vec();
        let record = EnsuredRecord {
            key: key.to_string(),
            spec_hash: requested_spec_hash,
            instance_id: instance_id.clone(),
            generation: 1,
            restored: false,
        };
        let _persist_guard = self
            .ensured_persist_lock
            .lock()
            .map_err(|_| EnsureError::Internal("ensured persistence lock poisoned"))?;
        self.surfaces
            .write()
            .map_err(|_| EnsureError::Internal("surface registry poisoned"))?
            .insert(surface_id.to_vec(), surface.clone());
        self.ensured
            .write()
            .map_err(|_| EnsureError::Internal("ensured registry poisoned"))?
            .insert(surface_id.to_vec(), record);
        if let Err(error) = self.persist_ensured_locked() {
            self.surfaces.write().unwrap().remove(surface_id);
            self.ensured.write().unwrap().remove(surface_id);
            surface.hangup();
            return Err(EnsureError::Persistence(error));
        }

        Ok(EnsureOutcome {
            disposition: EnsureDisposition::Created,
            pid: surface.pid() as i64,
            surface,
            surface_id: surface_id.to_vec(),
            instance_id,
            generation: 1,
            spec_hash: requested_spec_hash,
        })
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
        let Ok(reservation) = self.surface_reservation(&surface_id) else {
            tracing::error!("failed to reserve PTY surface {}", hex_short(&surface_id));
            return;
        };
        {
            let Ok(_guard) = reservation.lock() else {
                tracing::error!("PTY surface reservation poisoned");
                return;
            };
            if self.surfaces.read().unwrap().contains_key(&surface_id)
                || self.ensured.read().unwrap().contains_key(&surface_id)
            {
                tracing::warn!(
                    "refusing to overwrite occupied PTY surface {}",
                    hex_short(&surface_id)
                );
            } else {
                match spawn_from_spec(&surface_id, &spec) {
                    Ok(surface) => {
                        self.surfaces
                            .write()
                            .unwrap()
                            .insert(surface_id.clone(), surface);
                        self.specs.write().unwrap().insert(surface_id.clone(), spec);
                        if ephemeral {
                            self.ephemeral_specs
                                .write()
                                .unwrap()
                                .insert(surface_id.clone());
                        }
                        tracing::info!("spawned default PTY surface");
                    }
                    Err(e) => {
                        tracing::error!("failed to spawn default PTY surface: {e}");
                    }
                }
            }
        }
        self.release_surface_reservation(&surface_id, &reservation);
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
        match self.remove_inner(surface_id, false) {
            Ok(removed) => removed,
            Err(error) => {
                tracing::error!(
                    "failed to remove PTY surface {}: {error}",
                    hex_short(surface_id)
                );
                false
            }
        }
    }

    /// Explicit ensured-runner termination is transactional with its durable
    /// logical record. A failed save leaves the live process and registries
    /// intact and returns the persistence error to the RPC layer.
    pub fn terminate_ensured(&self, surface_id: &[u8]) -> Result<bool, EnsureError> {
        self.remove_inner(surface_id, true)
    }

    fn remove_inner(&self, surface_id: &[u8], require_ensured: bool) -> Result<bool, EnsureError> {
        if !self.begin_close(surface_id) {
            return Err(EnsureError::Internal("closing registry poisoned"));
        }

        let reservation = match self.surface_reservation(surface_id) {
            Ok(reservation) => reservation,
            Err(error) => {
                self.end_close(surface_id);
                return Err(error);
            }
        };
        let result = (|| -> Result<bool, EnsureError> {
            let _guard = reservation
                .lock()
                .map_err(|_| EnsureError::Internal("surface reservation poisoned"))?;
            if require_ensured && !self.ensured.read().unwrap().contains_key(surface_id) {
                return Ok(false);
            }
            let removed = self.surfaces.write().unwrap().remove(surface_id);
            let ephemeral = self.ephemeral_specs.write().unwrap().remove(surface_id);
            let ephemeral_spec = if ephemeral {
                self.specs.write().unwrap().remove(surface_id)
            } else {
                None
            };
            let persist_guard = match self.ensured_persist_lock.lock() {
                Ok(guard) => guard,
                Err(_) => {
                    if let Some(surface) = removed {
                        self.surfaces
                            .write()
                            .unwrap()
                            .insert(surface_id.to_vec(), surface);
                    }
                    if ephemeral {
                        self.ephemeral_specs
                            .write()
                            .unwrap()
                            .insert(surface_id.to_vec());
                    }
                    if let Some(spec) = ephemeral_spec {
                        self.specs
                            .write()
                            .unwrap()
                            .insert(surface_id.to_vec(), spec);
                    }
                    return Err(EnsureError::Internal("ensured persistence lock poisoned"));
                }
            };
            let logical_removed = self.ensured.write().unwrap().remove(surface_id);
            if logical_removed.is_some() {
                if let Err(error) = self.persist_ensured_locked() {
                    if let Some(logical_record) = logical_removed {
                        self.ensured
                            .write()
                            .unwrap()
                            .insert(surface_id.to_vec(), logical_record);
                    }
                    if let Some(surface) = removed {
                        self.surfaces
                            .write()
                            .unwrap()
                            .insert(surface_id.to_vec(), surface);
                    }
                    if ephemeral {
                        self.ephemeral_specs
                            .write()
                            .unwrap()
                            .insert(surface_id.to_vec());
                    }
                    if let Some(spec) = ephemeral_spec {
                        self.specs
                            .write()
                            .unwrap()
                            .insert(surface_id.to_vec(), spec);
                    }
                    drop(persist_guard);
                    return Err(EnsureError::Persistence(error));
                }
            }
            drop(persist_guard);
            if let Some(surface) = &removed {
                // Destructive terminate: guarantee the process is gone (SIGHUP
                // → grace → SIGKILL → reap), not just signaled. `hangup()`
                // alone let a SIGHUP-ignoring child (macOS forkpty session
                // leader) survive as an orphan while its reader kept the
                // surface Arc — and never Drop — alive.
                surface.shutdown_forcibly();
            }
            Ok(removed.is_some() || logical_removed.is_some())
        })();
        self.end_close(surface_id);
        self.release_surface_reservation(surface_id, &reservation);
        result
    }

    /// Return a live surface for `surface_id`, respawning if the
    /// previously-registered instance has exited. Returns `None` when the
    /// id is unknown (no surface ever registered) or when respawn fails.
    pub fn get_or_respawn(&self, surface_id: &[u8]) -> Option<Arc<PtySurface>> {
        let reservation = self.surface_reservation(surface_id).ok()?;
        let result = {
            let _guard = reservation.lock().ok()?;
            self.get_or_respawn_locked(surface_id)
        };
        self.release_surface_reservation(surface_id, &reservation);
        result
    }

    fn get_or_respawn_locked(&self, surface_id: &[u8]) -> Option<Arc<PtySurface>> {
        if self
            .closing
            .lock()
            .ok()?
            .get(surface_id)
            .copied()
            .unwrap_or(0)
            > 0
        {
            return None;
        }
        if let Some(s) = self.surfaces.read().unwrap().get(surface_id) {
            if s.is_live() {
                return Some(s.clone());
            }
        }

        let spec = self.specs.read().unwrap().get(surface_id).cloned()?;

        let mut surfaces = self.surfaces.write().unwrap();
        // Re-check under the write lock: another caller may have just
        // respawned between our read-lock check and now.
        if let Some(s) = surfaces.get(surface_id) {
            if s.is_live() {
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
        let surface_id = surface.surface_id.clone();
        let Ok(reservation) = self.surface_reservation(&surface_id) else {
            surface.hangup();
            return;
        };
        {
            let Ok(_guard) = reservation.lock() else {
                surface.hangup();
                return;
            };
            let mut surfaces = self.surfaces.write().unwrap();
            if surfaces.contains_key(&surface_id) {
                drop(surfaces);
                surface.hangup();
            } else {
                surfaces.insert(surface_id.clone(), surface);
            }
        }
        self.release_surface_reservation(&surface_id, &reservation);
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

    fn ensure_spec() -> SurfaceSpec {
        SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/cat".into(),
            args: Vec::new(),
            restart_policy: EnsureRestartPolicy::OnDaemonRestart,
        }
    }

    fn alternate_ensure_spec() -> SurfaceSpec {
        SurfaceSpec {
            cwd: "/tmp".into(),
            executable: "/bin/sh".into(),
            args: vec!["-c".into(), "exec cat".into()],
            restart_policy: EnsureRestartPolicy::OnDaemonRestart,
        }
    }

    fn stop_ensured(manager: &PtyManager, outcome: &EnsureOutcome) {
        manager.remove(&outcome.surface_id);
    }

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

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_exit_detection_and_hangup_have_single_owners() {
        let surface = cat_surface();
        let barrier = Arc::new(std::sync::Barrier::new(16));
        let mut tasks = Vec::new();
        for index in 0..16 {
            let surface = surface.clone();
            let barrier = barrier.clone();
            tasks.push(tokio::task::spawn_blocking(move || {
                barrier.wait();
                if index % 2 == 0 {
                    surface.hangup();
                } else {
                    let _ = surface.child_has_exited();
                }
            }));
        }
        for task in tasks {
            task.await.expect("lifecycle join");
        }

        let reaped = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if surface.child_has_exited() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await;
        assert!(
            reaped.is_ok(),
            "signaled child was not observed/reaped before timeout"
        );
        assert_eq!(surface.signal_owners.load(Ordering::Relaxed), 1);
        assert_eq!(surface.reap_owners.load(Ordering::Relaxed), 1);
        assert_eq!(surface.child.lock().unwrap().state, ChildState::Reaped);
        surface.hangup();
        assert_eq!(surface.signal_owners.load(Ordering::Relaxed), 1);
    }

    /// `Abandoned` is terminal. It is reached when a SIGKILLed child cannot be
    /// reaped inside the teardown window, and the pid was therefore never
    /// waited on — so from that point nothing may signal it again (it can be
    /// recycled), nothing may block on it again, and the surface must read as
    /// dead. Before the bounded reap existed there was no such state: the
    /// teardown simply blocked in `waitpid` forever, hanging every caller of
    /// `remove()` — pane close and workspace delete included.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_abandoned_child_is_terminal_and_never_signalled_again() {
        let surface = PtySurface::spawn(
            surface_id_from_name("abandoned-contract"),
            "cat".into(),
            "/bin/cat",
            &[],
            80,
            24,
            None,
        )
        .expect("spawn /bin/cat");

        // Reap it for real first, so the live child does not outlive the test,
        // then drive the state to Abandoned as an unreapable child would.
        surface.shutdown_forcibly();
        let signals_before = surface.signal_owners.load(Ordering::Relaxed);
        let reaps_before = surface.reap_owners.load(Ordering::Relaxed);
        surface.child.lock().unwrap().state = ChildState::Abandoned;

        // Reads as gone...
        assert!(
            surface.child_has_exited(),
            "an abandoned child must read as exited"
        );
        assert!(!surface.is_live(), "an abandoned surface must not be live");

        // ...and every lifecycle call is now a no-op: no new signal, no new
        // wait, and — the point of the fix — it RETURNS.
        surface.hangup();
        surface.shutdown_forcibly();
        assert_eq!(
            surface.signal_owners.load(Ordering::Relaxed),
            signals_before,
            "an abandoned pid must never be signalled again"
        );
        assert_eq!(
            surface.reap_owners.load(Ordering::Relaxed),
            reaps_before,
            "an abandoned pid must never be waited on again"
        );
        assert_eq!(
            surface.child.lock().unwrap().state,
            ChildState::Abandoned,
            "Abandoned is terminal"
        );
    }

    /// A destructive terminate must leave no live process, even when the
    /// child ignores SIGHUP. `hangup()` alone reaped only children that
    /// honored SIGHUP (the reader hit EOF and unwound the Arc/Drop chain); a
    /// child that traps HUP — the shape a macOS forkpty session leader takes
    /// — kept the reader blocked and the surface Arc alive forever, so the
    /// runner reported TERMINATED while the process leaked as an orphan.
    /// `shutdown_forcibly` escalates to SIGKILL, so here a HUP-ignoring child
    /// is gone and reaped before the call returns.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn shutdown_forcibly_kills_a_sighup_ignoring_child() {
        let surface = PtySurface::spawn(
            surface_id_from_name("force-kill-hup-ignorer"),
            "hup-ignorer".into(),
            "/bin/sh",
            &["-c", "trap '' HUP; read _line"],
            80,
            24,
            None,
        )
        .expect("spawn /bin/sh HUP-ignorer");

        let pid = surface.pid();
        assert!(pid > 0, "spawned child must have a real pid");
        // The child is alive and signalable before we terminate it.
        assert_eq!(
            unsafe { libc::kill(pid, 0) },
            0,
            "child should be alive pre-terminate"
        );

        // Blocking teardown off the async workers, mirroring how the runner's
        // sync terminate path reaches this.
        let s = surface.clone();
        tokio::task::spawn_blocking(move || s.shutdown_forcibly())
            .await
            .expect("shutdown_forcibly join");

        // The child was force-killed and reaped exactly once.
        assert_eq!(surface.child.lock().unwrap().state, ChildState::Reaped);
        assert_eq!(surface.reap_owners.load(Ordering::Relaxed), 1);
        // Its pid is gone: `kill(pid, 0)` now fails with ESRCH. The number is
        // not recycled in the microseconds between reap and this check.
        assert_eq!(
            unsafe { libc::kill(pid, 0) },
            -1,
            "terminated child must no longer be signalable"
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH),
            "terminated child pid must be gone (ESRCH)"
        );

        // Idempotent: a second forced shutdown on the reaped surface is a
        // no-op (no re-signal of a now-recycled pid, no second reap).
        let s2 = surface.clone();
        tokio::task::spawn_blocking(move || s2.shutdown_forcibly())
            .await
            .expect("second shutdown_forcibly join");
        assert_eq!(surface.reap_owners.load(Ordering::Relaxed), 1);
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
            assert_ne!(
                Some(result.as_str()),
                candidate,
                "must not echo back a blocked candidate"
            );
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

    #[test]
    fn surface_spec_hash_is_canonical_and_boundary_safe() {
        let base = ensure_spec();
        assert_eq!(base.canonical_hash(), base.clone().canonical_hash());

        let mut changed = base.clone();
        changed.cwd.push_str("/other");
        assert_ne!(base.canonical_hash(), changed.canonical_hash());

        let left = SurfaceSpec {
            args: vec!["a".into(), "bc".into()],
            ..base.clone()
        };
        let right = SurfaceSpec {
            args: vec!["ab".into(), "c".into()],
            ..base
        };
        assert_ne!(left.canonical_hash(), right.canonical_hash());
    }

    #[tokio::test]
    async fn ensure_rejects_invalid_keys_before_reservation_lookup() {
        let manager = PtyManager::new();
        assert!(matches!(
            manager.ensure("", &ensure_spec()),
            Err(EnsureError::InvalidKey(_))
        ));
        assert!(matches!(
            manager.ensure(&"x".repeat(257), &ensure_spec()),
            Err(EnsureError::InvalidKey(_))
        ));
        assert!(matches!(
            manager.ensure(&"가".repeat(86), &ensure_spec()),
            Err(EnsureError::InvalidKey(_))
        ));
        assert!(manager.surface_reservations.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn failing_unique_keys_do_not_grow_reservation_registry() {
        let manager = PtyManager::new();
        let mut spec = ensure_spec();
        spec.cwd = "/term-mesh/no-such-runner-directory".into();
        for index in 0..512 {
            assert!(matches!(
                manager.ensure(&format!("failing-runner-{index}"), &spec),
                Err(EnsureError::Spawn(_))
            ));
        }
        assert!(manager.surface_reservations.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn ensure_reuses_one_instance_across_ten_sequential_calls() {
        let manager = PtyManager::new();
        let spec = ensure_spec();
        let first = manager.ensure("sequential-runner", &spec).expect("create");
        assert_eq!(first.disposition, EnsureDisposition::Created);

        for _ in 0..9 {
            let reused = manager.ensure("sequential-runner", &spec).expect("reuse");
            assert_eq!(reused.disposition, EnsureDisposition::Reused);
            assert_eq!(reused.surface_id, first.surface_id);
            assert_eq!(reused.instance_id, first.instance_id);
            assert_eq!(reused.pid, first.pid);
            assert_eq!(reused.spec_hash, first.spec_hash);
            assert!(Arc::ptr_eq(&reused.surface, &first.surface));
        }
        stop_ensured(&manager, &first);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn ensure_coalesces_twenty_concurrent_identical_requests() {
        const CALLERS: usize = 20;
        let manager = Arc::new(PtyManager::new());
        let barrier = Arc::new(std::sync::Barrier::new(CALLERS));
        let mut tasks = Vec::with_capacity(CALLERS);
        for _ in 0..CALLERS {
            let manager = manager.clone();
            let barrier = barrier.clone();
            tasks.push(tokio::task::spawn_blocking(move || {
                barrier.wait();
                manager.ensure("concurrent-runner", &ensure_spec())
            }));
        }

        let mut outcomes = Vec::with_capacity(CALLERS);
        for task in tasks {
            outcomes.push(task.await.expect("join").expect("ensure"));
        }
        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| outcome.disposition == EnsureDisposition::Created)
                .count(),
            1
        );
        let first = &outcomes[0];
        assert!(outcomes.iter().all(|outcome| {
            outcome.surface_id == first.surface_id
                && outcome.instance_id == first.instance_id
                && outcome.pid == first.pid
                && Arc::ptr_eq(&outcome.surface, &first.surface)
        }));
        assert!(manager.surface_reservations.lock().unwrap().is_empty());
        stop_ensured(&manager, first);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_incompatible_ensure_never_replaces_winner() {
        let manager = Arc::new(PtyManager::new());
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let specs = [ensure_spec(), alternate_ensure_spec()];
        let mut tasks = Vec::new();
        for spec in specs {
            let manager = manager.clone();
            let barrier = barrier.clone();
            tasks.push(tokio::task::spawn_blocking(move || {
                barrier.wait();
                let result = manager.ensure("conflict-runner", &spec);
                (spec, result)
            }));
        }

        let mut winner = None;
        let mut conflict = None;
        for task in tasks {
            let (spec, result) = task.await.expect("join");
            match result {
                Ok(outcome) => winner = Some((spec, outcome)),
                Err(EnsureError::SpecConflict {
                    existing_spec_hash,
                    requested_spec_hash,
                    ..
                }) => conflict = Some((existing_spec_hash, requested_spec_hash)),
                Err(error) => panic!("unexpected ensure error: {error}"),
            }
        }

        let (winning_spec, winning_outcome) = winner.expect("one winner");
        let (existing_hash, requested_hash) = conflict.expect("one conflict");
        assert_eq!(existing_hash, winning_spec.canonical_hash());
        assert_ne!(existing_hash, requested_hash);
        let reused = manager
            .ensure("conflict-runner", &winning_spec)
            .expect("winner remains reusable");
        assert_eq!(reused.pid, winning_outcome.pid);
        assert_eq!(reused.instance_id, winning_outcome.instance_id);
        stop_ensured(&manager, &winning_outcome);
    }

    #[test]
    fn unrelated_keys_receive_independent_reservations() {
        let manager = PtyManager::new();
        let left_id = surface_id_from_name("runner-left");
        let right_id = surface_id_from_name("runner-right");
        let left = manager.surface_reservation(&left_id).unwrap();
        let right = manager.surface_reservation(&right_id).unwrap();
        assert!(!Arc::ptr_eq(&left, &right));

        let _left_guard = left.lock().unwrap();
        assert!(
            right.try_lock().is_ok(),
            "a reservation held for one key must not block another key"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn ensure_racing_remove_never_reuses_the_closing_instance() {
        let manager = Arc::new(PtyManager::new());
        let spec = ensure_spec();
        let first = manager.ensure("remove-race", &spec).expect("create");
        let surface_id = first.surface_id.clone();

        // Hold the shared boundary so remove can publish close intent but not
        // complete. The racing ensure must observe that intent once admitted.
        let reservation = manager.surface_reservation(&surface_id).unwrap();
        let guard = reservation.lock().unwrap();
        let removing = {
            let manager = manager.clone();
            let surface_id = surface_id.clone();
            tokio::task::spawn_blocking(move || manager.remove(&surface_id))
        };
        loop {
            if manager
                .closing
                .lock()
                .unwrap()
                .get(&surface_id)
                .copied()
                .unwrap_or(0)
                > 0
            {
                break;
            }
            tokio::task::yield_now().await;
        }
        let ensuring = {
            let manager = manager.clone();
            let spec = spec.clone();
            tokio::task::spawn_blocking(move || manager.ensure("remove-race", &spec))
        };
        drop(guard);

        assert!(removing.await.expect("remove join"));
        match ensuring.await.expect("ensure join") {
            Ok(outcome) => {
                assert_ne!(
                    outcome.disposition,
                    EnsureDisposition::Reused,
                    "ensure reused a process after close intent"
                );
                assert_ne!(outcome.instance_id, first.instance_id);
                stop_ensured(&manager, &outcome);
            }
            Err(EnsureError::NotRunning(_)) => {}
            Err(error) => panic!("unexpected ensure error: {error}"),
        }
        drop(reservation);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn two_removes_keep_close_intent_until_both_complete() {
        let manager = Arc::new(PtyManager::new());
        let spec = ensure_spec();
        let first = manager.ensure("double-remove-race", &spec).expect("create");
        let surface_id = first.surface_id.clone();
        let reservation = manager.surface_reservation(&surface_id).unwrap();
        let guard = reservation.lock().unwrap();

        let mut removals = Vec::new();
        for _ in 0..2 {
            let manager = manager.clone();
            let surface_id = surface_id.clone();
            removals.push(tokio::task::spawn_blocking(move || {
                manager.remove(&surface_id)
            }));
        }
        loop {
            if manager
                .closing
                .lock()
                .unwrap()
                .get(&surface_id)
                .copied()
                .unwrap_or(0)
                == 2
            {
                break;
            }
            tokio::task::yield_now().await;
        }
        let ensuring = {
            let manager = manager.clone();
            let spec = spec.clone();
            tokio::task::spawn_blocking(move || manager.ensure("double-remove-race", &spec))
        };
        drop(guard);

        let mut removed_count = 0;
        for removal in removals {
            removed_count += usize::from(removal.await.expect("remove join"));
        }
        assert_eq!(removed_count, 1);
        match ensuring.await.expect("ensure join") {
            Ok(outcome) => {
                assert_ne!(outcome.disposition, EnsureDisposition::Reused);
                assert_ne!(outcome.instance_id, first.instance_id);
                stop_ensured(&manager, &outcome);
            }
            Err(EnsureError::NotRunning(_)) => {}
            Err(error) => panic!("unexpected ensure error: {error}"),
        }
        assert_eq!(
            manager
                .closing
                .lock()
                .unwrap()
                .get(&surface_id)
                .copied()
                .unwrap_or(0),
            0
        );
        drop(reservation);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn register_and_ensure_collision_never_overwrites_or_orphans() {
        let manager = Arc::new(PtyManager::new());
        let key = "namespace-collision";
        let surface_id = surface_id_from_name(key);
        let barrier = Arc::new(std::sync::Barrier::new(2));

        let ensuring = {
            let manager = manager.clone();
            let barrier = barrier.clone();
            tokio::task::spawn_blocking(move || {
                barrier.wait();
                manager.ensure(key, &ensure_spec())
            })
        };
        let registering = {
            let manager = manager.clone();
            let barrier = barrier.clone();
            let surface_id = surface_id.clone();
            tokio::task::spawn_blocking(move || {
                barrier.wait();
                manager.register_and_spawn(
                    surface_id,
                    SpawnSpec {
                        title: "registered-collision".into(),
                        command: "/bin/cat".into(),
                        args: Vec::new(),
                        cols: 80,
                        rows: 24,
                        cwd: Some("/tmp".into()),
                    },
                );
            })
        };

        let ensure_result = ensuring.await.expect("ensure join");
        registering.await.expect("register join");
        assert_eq!(manager.list().len(), 1);
        let ensured_count = usize::from(manager.ensured.read().unwrap().contains_key(&surface_id));
        let registered_count = usize::from(manager.specs.read().unwrap().contains_key(&surface_id));
        assert_eq!(ensured_count + registered_count, 1);
        match ensure_result {
            Ok(outcome) => {
                assert_eq!(ensured_count, 1);
                assert_eq!(outcome.surface_id, surface_id);
            }
            Err(EnsureError::SpecConflict { .. }) => assert_eq!(registered_count, 1),
            Err(error) => panic!("unexpected ensure error: {error}"),
        }
        assert!(manager.remove(&surface_id));
    }

    // ── Replay capacity (t11: TERMMESH_PEER_REPLAY_BYTES env + RPC/CLI) ──

    #[test]
    fn parse_replay_bytes_accepts_plain_integer() {
        assert_eq!(parse_and_clamp_replay_bytes("262144"), Ok((262144, false)));
        // Leading/trailing whitespace (e.g. from a shell env file) is trimmed.
        assert_eq!(
            parse_and_clamp_replay_bytes(" 262144 \n"),
            Ok((262144, false))
        );
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
            buf.push(PtyChunk {
                seq,
                bytes: vec![0u8; 1024],
            });
        }
        assert!(
            buf.bytes <= REPLAY_CAPACITY_MIN_BYTES,
            "expected eviction down to the lowered capacity, got {} bytes",
            buf.bytes
        );
        let kept: Vec<u64> = buf.snapshot().iter().map(|c| c.seq).collect();
        assert_eq!(
            kept,
            vec![4, 5, 6, 7],
            "oldest chunks must be evicted first (FIFO)"
        );

        set_replay_capacity(original).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn persisted_ensure_recreates_exactly_once_after_daemon_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-ensured-surfaces.json");
        let first_manager = PtyManager::new();
        first_manager.set_ensured_persist_path(path.clone());
        let first = first_manager
            .ensure("restart-runner", &ensure_spec())
            .expect("initial create");
        assert_eq!(first.disposition, EnsureDisposition::Created);
        let old_instance = first.instance_id.clone();
        let old_pid = first.pid;
        first.surface.hangup();
        drop(first);
        drop(first_manager);

        let restarted = Arc::new(PtyManager::new());
        restarted.set_ensured_persist_path(path);
        let tasks: Vec<_> = (0..20)
            .map(|_| {
                let manager = Arc::clone(&restarted);
                tokio::task::spawn_blocking(move || {
                    manager.ensure("restart-runner", &ensure_spec())
                })
            })
            .collect();
        let outcomes = tokio::time::timeout(std::time::Duration::from_secs(5), async {
            let mut outcomes = Vec::new();
            for (index, task) in tasks.into_iter().enumerate() {
                outcomes.push(
                    task.await
                        .unwrap_or_else(|error| panic!("recreate worker {index} join: {error}"))
                        .unwrap_or_else(|error| panic!("recreate worker {index} ensure: {error}")),
                );
            }
            outcomes
        })
        .await
        .expect("concurrent recreate exceeded 5s (reservation/persistence lock deadlock)");

        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| outcome.disposition == EnsureDisposition::Recreated)
                .count(),
            1
        );
        assert!(outcomes
            .iter()
            .skip(1)
            .all(|outcome| outcome.generation == 2));
        let recreated = outcomes
            .iter()
            .find(|outcome| outcome.disposition == EnsureDisposition::Recreated)
            .unwrap();
        assert_eq!(recreated.surface_id, surface_id_from_name("restart-runner"));
        assert_ne!(recreated.instance_id, old_instance);
        assert_ne!(recreated.pid, old_pid);
        restarted.remove(&recreated.surface_id);
    }

    #[tokio::test]
    async fn terminate_removes_runtime_and_persisted_logical_record_idempotently() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer-ensured-surfaces.json");
        let manager = PtyManager::new();
        manager.set_ensured_persist_path(path.clone());
        let created = manager
            .ensure("terminate-runner", &ensure_spec())
            .expect("create");
        assert_eq!(super::super::persist::load_ensured_surfaces(&path).len(), 1);

        assert!(manager.terminate_ensured(&created.surface_id).unwrap());
        assert!(!manager.terminate_ensured(&created.surface_id).unwrap());
        assert!(manager.list().is_empty());
        assert!(super::super::persist::load_ensured_surfaces(&path).is_empty());
    }
}
