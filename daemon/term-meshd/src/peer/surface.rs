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

const READ_BUF_SIZE: usize = 65536; // EXPERIMENT: was 4096 — coalescing knob #2 (fewer, larger PtyChunks under flood)
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
///
/// Raised from 1 MiB to 32 MiB (2026-07-21) after a measured bulk-flood
/// relay run lost ~23 MB of output that had already scrolled out of a 1 MiB
/// ring before the relay could resume/replay it; 32 MiB comfortably covers
/// that flood plus headroom. 64 MiB was rejected as the default — it doubles
/// the standing per-surface cost below for a case 32 MiB already covers.
///
/// Standing memory cost: `ReplayBuffer` (below) does NOT eagerly
/// pre-allocate this many bytes. It is a `VecDeque<PtyChunk>` that grows
/// lazily as PTY output actually arrives via `push`, trimming from the front
/// once buffered bytes exceed the capacity — so an idle or low-output
/// surface costs close to nothing. This constant is a per-surface *upper
/// bound*: a surface that has produced at least this much output pins up to
/// this many bytes (plus `PtyChunk`/`VecDeque` overhead) for as long as it
/// stays attached-replay-eligible, and that cost multiplies by the number of
/// concurrently live surfaces.
const REPLAY_CAPACITY_DEFAULT_BYTES: usize = 32 * 1024 * 1024; // 32 MiB
/// Bytes of recent PTY output a *fresh* attach (one that sends no
/// `resume_from_seq`) is replayed, independent of the ring's capacity above.
///
/// These are deliberately two numbers. The capacity is sized for *resume*:
/// after a bulk-flood gap the client asks for an exact range and the ring must
/// still hold it, hence 32 MiB. A fresh attach has no such range to ask for —
/// it only needs enough trailing output to render a sane screen, the "shell
/// prompt printed before the SSH relay attached" case the capacity doc
/// describes. Handing it the entire ring instead meant re-opening a surface
/// that had once run something noisy re-streamed megabytes, which reads on
/// screen as the old command scrolling past all over again.
///
/// 64 KiB matches the macOS host's own replay ring
/// (`GhosttyPaneSurfaceProvider.swift`'s `replayCapacityBytes`), so the two
/// host implementations hand a fresh viewer a comparable amount of history.
const FRESH_ATTACH_REPLAY_BYTES: usize = 64 * 1024; // 64 KiB
/// Lower bound accepted for the replay capacity (env or RPC/CLI set).
const REPLAY_CAPACITY_MIN_BYTES: usize = 4 * 1024; // 4 KiB
/// Upper bound accepted for the replay capacity (env or RPC/CLI set).
/// Kept above `REPLAY_CAPACITY_DEFAULT_BYTES` so the default is always a
/// valid, non-clamped value for `parse_and_clamp_replay_bytes` /
/// `set_replay_capacity`.
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

#[derive(Clone, Debug, PartialEq, Eq)]
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

    /// The newest `max_bytes`-ish of the ring, as whole chunks.
    ///
    /// Exists because the ring's *capacity* and a *fresh attach's* replay
    /// size are two different requirements that used to share one number.
    /// `REPLAY_CAPACITY_DEFAULT_BYTES` is sized for resume (see its doc: 32
    /// MiB so a bulk flood's lost output is still recoverable via
    /// `snapshot_from`), but a fresh attach has nothing to resume — it just
    /// needs enough recent output to land on a sane screen. Replaying the
    /// whole ring there meant every re-open of a surface that had once run
    /// something noisy (a big `find`, a build log) re-streamed megabytes,
    /// which renders as the old command appearing to scroll past again.
    ///
    /// Cuts on chunk boundaries, never mid-chunk: a chunk is one PTY read,
    /// so keeping it whole avoids slicing the middle of an escape sequence
    /// that arrived in a single write. An escape sequence split *across*
    /// chunks can still be clipped at the cut — the same, already-accepted
    /// tradeoff `snapshot_from` makes for resume, and a repaint fixes it.
    ///
    /// The newest chunk is always included even if it alone exceeds
    /// `max_bytes`: returning nothing would leave the viewer blank, which is
    /// strictly worse than one oversized replay. PTY reads are bounded well
    /// below any sane `max_bytes`, so this is a guard, not a normal path.
    fn snapshot_tail(&self, max_bytes: usize) -> Vec<PtyChunk> {
        let mut selected: Vec<PtyChunk> = Vec::new();
        let mut total: usize = 0;
        for chunk in self.chunks.iter().rev() {
            if !selected.is_empty() && total.saturating_add(chunk.bytes.len()) > max_bytes {
                break;
            }
            total = total.saturating_add(chunk.bytes.len());
            selected.push(chunk.clone());
        }
        selected.reverse();
        selected
    }

    /// `snapshot()`, cut to only the bytes at or after `from_seq`.
    ///
    /// `from_seq` is on the same absolute scale as `PtyChunk::seq`
    /// (host-side monotonic byte offset — see `PtySurface::byte_seq`).
    /// Mapping a wire-side, per-attach-reset seq onto this scale is the
    /// caller's job (see connection.rs's resume handling); this method only
    /// knows how to cut the ring it already holds.
    ///
    /// - `from_seq == 0` is satisfied by every chunk (`chunk.seq >= 0` is
    ///   trivially true for `u64`), so this degenerates to `snapshot()` for a
    ///   fresh attach that has nothing to resume from — callers do not need
    ///   to special-case "first attach" vs "resume".
    /// - When `from_seq` falls inside the currently buffered range
    ///   (`oldest_seq..=end`, where `end` is one past the last buffered
    ///   byte), only bytes at or after it are returned. A chunk that
    ///   straddles the cut point is trimmed rather than kept or dropped
    ///   whole, so no already-seen byte is resent and no buffered byte is
    ///   skipped.
    /// - When `from_seq` is outside that range — older than what the ring
    ///   still holds (the gap between it and the resume point was already
    ///   evicted, so an exact resume is impossible) or newer than anything
    ///   ever buffered (seq-space mismatch) — an exact cut can't be honored,
    ///   so this falls back to the full snapshot. Resending bytes the
    ///   client may already have is preferable to the silent drop this
    ///   whole mechanism exists to fix.
    ///
    /// All arithmetic saturates instead of panicking on overflow, so a seq
    /// value near `u64::MAX` (never reached in practice — it would take
    /// exabytes of PTY output — but defended against here) degrades to a
    /// safe fallback instead of a panic.
    fn snapshot_from(&self, from_seq: u64) -> Vec<PtyChunk> {
        let (Some(first), Some(last)) = (self.chunks.front(), self.chunks.back()) else {
            return Vec::new();
        };
        let oldest_seq = first.seq;
        let end = last.seq.saturating_add(last.bytes.len() as u64);
        if from_seq < oldest_seq || from_seq > end {
            return self.snapshot();
        }
        let mut out = Vec::with_capacity(self.chunks.len());
        for chunk in &self.chunks {
            let chunk_end = chunk.seq.saturating_add(chunk.bytes.len() as u64);
            if chunk_end <= from_seq {
                // Entirely before the resume point — already seen.
                continue;
            }
            if chunk.seq >= from_seq {
                out.push(chunk.clone());
            } else {
                // Straddles the cut point: keep only the unseen tail.
                let skip = (from_seq - chunk.seq) as usize;
                out.push(PtyChunk {
                    seq: from_seq,
                    bytes: chunk.bytes[skip..].to_vec(),
                });
            }
        }
        out
    }
}

/// Per-surface terminal emulator: the host's own model of what the screen
/// looks like *right now*, fed the same filtered bytes every client sees.
///
/// This is what lets a fresh attach receive the current screen instead of a
/// byte-history replay — the tmux model. The replay ring keeps its scrollback
/// role; this struct owns the "visible screen" role the ring used to fake by
/// replaying a tail (`FRESH_ATTACH_REPLAY_BYTES`), which blanked idle TUIs.
///
/// Lives behind one `Mutex` together with `fed_through`, so a reader gets an
/// atomic (screen, seq) pair: a snapshot is meaningless without knowing which
/// byte position it is consistent with (`GridSnapshot.byte_seq` on the wire).
struct ScreenModel {
    parser: vt100::Parser,
    /// Host-absolute `byte_seq` position this screen has consumed up to: the
    /// END seq of the last chunk fed (i.e. `chunk.seq + chunk.bytes.len()`).
    /// An attach that dedupes live chunks below this value will never apply
    /// a byte the snapshot already contains, and never miss one it doesn't.
    fed_through: u64,
}

/// Rows of host-side scrollback kept per surface for the on-demand
/// scrollback path (tmux copy-mode model). Matches tmux's own
/// `history-limit` default. At 80 cols a row costs ~2.9 KB once actually
/// scrolled into — ~5.8 MB per busy surface — but allocation is lazy
/// (vt100 grows the deque as lines scroll out), so idle surfaces pay
/// nothing.
const SCROLLBACK_ROWS_DEFAULT: usize = 2000;
/// Hard ceiling for the env override — scrollback is per-surface memory.
const SCROLLBACK_ROWS_MAX: usize = 10_000;

/// `TERMMESH_PEER_SCROLLBACK_ROWS`: rows of scrollback per surface. `0`
/// disables host-side scrollback (requests render nothing). Read at
/// surface spawn — vt100 fixes the scrollback length at parser
/// construction, so unlike the replay-ring capacity this cannot change on
/// a live surface.
fn scrollback_rows_from_env() -> usize {
    match std::env::var("TERMMESH_PEER_SCROLLBACK_ROWS") {
        Ok(raw) => match raw.trim().parse::<usize>() {
            Ok(n) => n.min(SCROLLBACK_ROWS_MAX),
            Err(_) => SCROLLBACK_ROWS_DEFAULT,
        },
        Err(_) => SCROLLBACK_ROWS_DEFAULT,
    }
}

impl ScreenModel {
    fn new(cols: u16, rows: u16) -> Self {
        ScreenModel {
            // vt100's constructor takes (rows, cols, scrollback) — the
            // reverse of this repo's (cols, rows) convention everywhere
            // else. Do not "fix" the argument order.
            parser: vt100::Parser::new(rows, cols, scrollback_rows_from_env()),
            fed_through: 0,
        }
    }

    /// Feed one filtered chunk and advance the consistency watermark.
    /// Split out as a method (rather than inlining in the reader loop) so a
    /// future batching layer — accumulate, feed on a tick — can slot in
    /// without touching the attach path.
    fn feed(&mut self, bytes: &[u8], end_seq: u64) {
        self.parser.process(bytes);
        self.fed_through = end_seq;
    }
}

pub struct PtySurface {
    pub surface_id: Vec<u8>,
    pub title: String,
    pub workspace_name: String,
    pub cols: AtomicU32,
    pub rows: AtomicU32,
    /// Directory the child was spawned in (absolute path when resolvable).
    /// Only a fallback for reporting: what a viewer is shown is where the
    /// shell is *now*, via [`PtySurface::current_cwd`].
    pub cwd: String,
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
    /// Per-attacher requested winsize, keyed by an opaque requester id (one
    /// per connection). A PTY has a single winsize, so concurrent viewers
    /// are arbitrated tmux-style: the PTY gets min(cols) × min(rows) across
    /// all live requests, and a departing attacher's request is dropped so
    /// the survivors get their size back. Replaces the last-writer-wins
    /// free-for-all that made two different-sized windows fight over the
    /// grid.
    size_requests: Mutex<HashMap<u64, (u16, u16)>>,
    /// The host-side screen model (see [`ScreenModel`]). Locked briefly by
    /// the reader loop per chunk and by attach-time snapshot reads; never
    /// held across an await.
    screen: Mutex<ScreenModel>,
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
        let child = pty::spawn(command, args, cols, rows, cwd, &pane_environment(&surface_id))?;
        pty::set_nonblocking(child.master_fd)?;
        let (tx, _rx) = broadcast::channel::<PtyChunk>(BROADCAST_CAPACITY);

        let resolved_cwd = cwd.map(|c| c.to_string()).unwrap_or_else(|| {
            std::env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default()
        });

        let surface = Arc::new(PtySurface {
            surface_id: surface_id.clone(),
            title,
            workspace_name: "peer-host".into(),
            cols: AtomicU32::new(cols as u32),
            rows: AtomicU32::new(rows as u32),
            cwd: resolved_cwd,
            broadcast_tx: tx.clone(),
            dead: AtomicBool::new(false),
            dead_notify: Notify::new(),
            byte_seq: AtomicU64::new(0),
            replay: Mutex::new(ReplayBuffer::default()),
            modes: Mutex::new(BTreeSet::new()),
            size_requests: Mutex::new(HashMap::new()),
            screen: Mutex::new(ScreenModel::new(cols, rows)),
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
                        // Feed the screen model BEFORE the broadcast: the
                        // attach handler captures its subscriber and then
                        // reads the snapshot, so any chunk a subscriber can
                        // observe must already be in the screen — otherwise
                        // a snapshot could lag `live_min_seq` and the viewer
                        // would apply a stale screen over newer live bytes.
                        // Only the FILTERED bytes are fed: `byte_seq`
                        // advances by `bytes.len()`, not the raw read size,
                        // so feeding raw would desync `fed_through` from the
                        // seq space every other consumer lives in.
                        if let Ok(mut screen) = reader_surface.screen.lock() {
                            screen.feed(&bytes, seq + bytes.len() as u64);
                        }
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

    /// The ring in full. No production attach path uses this any more —
    /// resume goes through `replay_snapshot_from` and a fresh attach through
    /// `replay_snapshot_fresh` — but it stays as the plain "everything
    /// buffered" accessor the tests assert against, and as the obvious
    /// counterpart to the two bounded readers below.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn replay_snapshot(&self) -> Vec<PtyChunk> {
        self.replay
            .lock()
            .map(|replay| replay.snapshot())
            .unwrap_or_default()
    }

    /// `replay_snapshot()`, cut to the tail starting at `from_seq`. See
    /// `ReplayBuffer::snapshot_from` for the exact cut/fallback semantics
    /// (in short: `from_seq == 0` matches `replay_snapshot()` exactly; a
    /// `from_seq` outside the ring's currently buffered range falls back to
    /// the full snapshot rather than resending nothing).
    pub fn replay_snapshot_from(&self, from_seq: u64) -> Vec<PtyChunk> {
        self.replay
            .lock()
            .map(|replay| replay.snapshot_from(from_seq))
            .unwrap_or_default()
    }

    /// `replay_snapshot()`, bounded to the newest `FRESH_ATTACH_REPLAY_BYTES`.
    /// The byte-replay fallback for a fresh attach — used when the screen
    /// model is unavailable (poisoned lock) or explicitly forced via
    /// `TERMMESH_PEER_FRESH_ATTACH_MODE=bytes`. The primary fresh-attach
    /// path is [`PtySurface::screen_snapshot`].
    pub fn replay_snapshot_fresh(&self) -> Vec<PtyChunk> {
        self.replay
            .lock()
            .map(|replay| replay.snapshot_tail(FRESH_ATTACH_REPLAY_BYTES))
            .unwrap_or_default()
    }

    /// Render the current screen as ANSI bytes, atomically paired with the
    /// host-absolute `byte_seq` the render is consistent with.
    ///
    /// This is the tmux model: a fresh attach gets the ONE current screen —
    /// cursor, styles, input modes — instead of a replay of recent history
    /// that either re-streams old output (full ring) or blanks an idle TUI
    /// (bounded tail). `state_formatted()` covers contents + cursor + input
    /// modes + title.
    ///
    /// Two deliberate additions around vt100's own output:
    /// - `ESC[?1049h` is prepended when the surface is on the alternate
    ///   screen. `state_formatted()` renders whichever grid is active but
    ///   never emits the mode switch itself; without it the viewer would
    ///   paint a TUI into its primary screen, and the app's eventual
    ///   `?1049l` would no-op — leaving the TUI on screen forever.
    /// - The caller still prepends `mode_replay_bytes()` (mouse DECSET):
    ///   vt100 tracks most input modes but not 1015/1016, which the host's
    ///   own tracker does. Overlapping DECSETs are idempotent; the
    ///   snapshot's version wins where both speak.
    ///
    /// Returns `None` on a poisoned lock — callers fall back to the byte
    /// replay path, matching the `.unwrap_or_default()` convention of the
    /// other snapshot readers.
    pub fn screen_snapshot(&self) -> Option<(Vec<u8>, u64)> {
        let screen = self.screen.lock().ok()?;
        let vt = screen.parser.screen();
        let mut out = Vec::new();
        if vt.alternate_screen() {
            out.extend_from_slice(b"\x1b[?1049h");
        }
        out.extend_from_slice(&vt.state_formatted());
        Some((out, screen.fed_through))
    }

    /// Render the scrollback window whose bottom sits `offset_rows` above
    /// the live view's bottom, as a full-screen replacement (clear+home
    /// first) — what a `ScrollbackRequest` gets back.
    ///
    /// Returns `(ansi, effective_offset, at_top, total_rows)`. The offset is
    /// clamped to what the scrollback actually holds; `at_top` reports that
    /// the render hit (or was clamped to) the oldest retained row. On the
    /// alternate screen the browse is meaningless (vt100's offset is a
    /// no-op against the alt grid, which never accumulates scrollback — the
    /// same rule tmux applies), so the render comes back empty with
    /// `at_top` set.
    ///
    /// The offset dance is atomic under the screen lock, and MUST be:
    /// vt100 auto-follows a nonzero offset when live output scrolls
    /// (`scrollback_offset + 1` per scrolled line), so an offset left
    /// dangling would silently pin every later snapshot to the past. The
    /// restore is to absolute 0, which is immune to that drift. `None` on a
    /// poisoned lock, like [`PtySurface::screen_snapshot`].
    pub fn scrollback_render(&self, offset_rows: u32) -> Option<(Vec<u8>, u32, bool, u32)> {
        let mut screen = self.screen.lock().ok()?;
        if screen.parser.screen().alternate_screen() {
            return Some((Vec::new(), 0, true, 0));
        }
        // Total retained rows: set_scrollback clamps to the deque's actual
        // length, and `Screen::scrollback()` reads the clamped offset back —
        // the only way the total is observable through vt100's public API.
        screen.parser.screen_mut().set_scrollback(usize::MAX);
        let total = screen.parser.screen().scrollback();
        screen.parser.screen_mut().set_scrollback(offset_rows as usize);
        let effective = screen.parser.screen().scrollback();
        let ansi = screen.parser.screen().contents_formatted();
        screen.parser.screen_mut().set_scrollback(0);
        let at_top = effective >= total || (effective as u64) < offset_rows as u64;
        Some((ansi, effective as u32, at_top, total as u32))
    }

    /// Current value of the surface's monotonic PTY byte-seq counter — the
    /// absolute `PtyChunk::seq` the NEXT produced chunk will start at.
    ///
    /// Used at attach time (`connection.rs`'s AttachSurface handler) to
    /// compute `AttachResult.initial_seq` when nothing is buffered in the
    /// replay ring yet: a brand-new surface, or one whose ring capacity was
    /// set low enough that it's currently empty. In that case the ring has
    /// no chunk to read a boundary seq off of, but the wire stream's first
    /// real byte (once one arrives) will be exactly this value — see that
    /// handler's doc comment for the full wire↔host seq mapping this feeds.
    pub fn current_byte_seq(&self) -> u64 {
        self.byte_seq.load(Ordering::Relaxed)
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
        // Keep the screen model at the PTY's size, or every later snapshot
        // renders at a stale width. vt100's set_size takes (rows, cols) —
        // the reverse of this function's own signature. Do not swap.
        if let Ok(mut screen) = self.screen.lock() {
            screen.parser.screen_mut().set_size(rows, cols);
        }
        Ok(())
    }

    /// Record `requester`'s desired winsize and apply the arbitrated
    /// minimum across all live requests (tmux-style: every viewer sees a
    /// grid that fits the smallest of them). Callers pair this with
    /// [`drop_size_request`] on detach; a raw [`resize`] bypasses
    /// arbitration and is reserved for single-writer paths (spawn).
    pub fn request_size(&self, requester: u64, cols: u16, rows: u16) -> std::io::Result<()> {
        let min = {
            let mut requests = self.size_requests.lock().unwrap();
            requests.insert(requester, (cols, rows));
            Self::arbitrated_min(&requests)
        };
        match min {
            Some((c, r)) => self.resize(c, r),
            None => Ok(()),
        }
    }

    /// Forget `requester`'s size request and re-apply the minimum of the
    /// survivors, so closing a small viewer gives the remaining ones their
    /// full grid back. No-op on the PTY when no requests remain — the last
    /// applied size simply persists.
    pub fn drop_size_request(&self, requester: u64) {
        let min = {
            let mut requests = self.size_requests.lock().unwrap();
            if requests.remove(&requester).is_none() {
                return;
            }
            Self::arbitrated_min(&requests)
        };
        if let Some((c, r)) = min {
            if let Err(e) = self.resize(c, r) {
                tracing::warn!("post-detach resize failed: {e}");
            }
        }
    }

    fn arbitrated_min(requests: &HashMap<u64, (u16, u16)>) -> Option<(u16, u16)> {
        let cols = requests.values().map(|&(c, _)| c).min()?;
        let rows = requests.values().map(|&(_, r)| r).min()?;
        Some((cols, rows))
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

    /// Where the shell sits *now*, not where it was spawned.
    ///
    /// A terminal normally learns this from the shell's own OSC 7 report, but
    /// that channel is closed to us by design: a pane hosted here is drawn on
    /// another machine, and a terminal refuses an OSC 7 whose hostname is not
    /// local — otherwise any SSH session could tell your terminal what its
    /// working directory is. Asking the OS instead sidesteps the terminal byte
    /// stream entirely, which also means it works for any shell with no shell
    /// integration installed and survives a shell restart.
    ///
    /// Best-effort by construction: a dead child, a platform without a lookup,
    /// or a permission failure all fall back to the spawn directory, so callers
    /// always get a usable path rather than an empty one.
    ///
    /// The lookup runs while the lifecycle lock is held, which is what makes a
    /// bare pid safe to use: reaping takes the same lock, so the child cannot
    /// be waited on — and its pid therefore cannot be recycled onto some
    /// unrelated process — between the state check and the read. The cost is a
    /// single filesystem-ish syscall under the lock, and this is only ever
    /// called when a snapshot is taken, never in a loop.
    pub fn current_cwd(&self) -> String {
        let Ok(child) = self.child.lock() else {
            return self.cwd.clone();
        };
        if child.state != ChildState::Running {
            return self.cwd.clone();
        }
        process_cwd(child.pid).unwrap_or_else(|| self.cwd.clone())
    }

    pub fn info(&self) -> SurfaceInfo {
        // Both are derived live. A branch pinned at spawn time would contradict
        // a cwd that has since moved into a different repository, and a viewer
        // showing that pair has no way to tell which of the two is stale.
        let cwd = self.current_cwd();
        let branch = resolve_git_branch(&cwd);
        SurfaceInfo {
            surface_id: self.surface_id.clone(),
            workspace_name: self.workspace_name.clone(),
            title: self.title.clone(),
            cols: self.cols.load(Ordering::Relaxed),
            rows: self.rows.load(Ordering::Relaxed),
            surface_type: "terminal".into(),
            attachable: self.is_live(),
            cwd,
            branch,
        }
    }
}

/// The working directory of `pid`, or `None` when it cannot be determined.
#[cfg(target_os = "linux")]
fn process_cwd(pid: libc::pid_t) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/cwd"))
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
}

/// The working directory of `pid`, or `None` when it cannot be determined.
///
/// macOS has no `/proc`, so this asks the kernel directly. `proc_pidinfo`
/// returns the count of bytes it filled in, and rejecting a short write keeps
/// a partially-populated struct from being read as a real path.
#[cfg(target_os = "macos")]
fn process_cwd(pid: libc::pid_t) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let written = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            (&raw mut info).cast(),
            size,
        )
    };
    if written != size {
        return None;
    }
    // `vip_path` is MAXPATHLEN laid out as chunked rows, so flatten before
    // looking for the NUL that ends the path.
    let bytes: Vec<u8> = info
        .pvi_cdir
        .vip_path
        .iter()
        .flatten()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    if bytes.is_empty() {
        return None;
    }
    String::from_utf8(bytes).ok()
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn process_cwd(_pid: libc::pid_t) -> Option<String> {
    None
}

/// Terminal this host claims to be when a better answer is unavailable.
/// Every system with terminfo at all has it, so it is a safe floor.
const FALLBACK_TERM: &str = "xterm-256color";
/// What panes are told they are talking to, when the machine can describe it.
const PREFERRED_TERM: &str = "xterm-ghostty";

/// What a pane's shell is told about the terminal it is attached to.
///
/// A pane started by the daemon inherits the daemon's own environment, which
/// under systemd contains no `TERM` whatsoever. A shell with no `TERM` cannot
/// tell what its terminal supports, so programs fall back to their dumbest
/// behaviour — and an agent deciding how to raise a notification concludes the
/// terminal supports none, which is why a remote pane stayed silent while an
/// identical local one did not.
///
/// Only what remains true on this machine is set. The viewer's own pane
/// environment carries paths into the Mac's app bundle (terminfo, shell
/// integration, its control socket); copying those here would point a remote
/// shell at directories that do not exist.
fn pane_environment(surface_id: &[u8]) -> Vec<(String, String)> {
    let mut env = vec![
        ("TERM".to_string(), resolve_term()),
        ("TERM_PROGRAM".to_string(), "ghostty".to_string()),
        (
            "TERM_PROGRAM_VERSION".to_string(),
            env!("CARGO_PKG_VERSION").to_string(),
        ),
        ("COLORTERM".to_string(), "truecolor".to_string()),
    ];
    // The pane's own identity, so anything running inside it can name the
    // surface it belongs to. Both spellings, matching what a local pane gets.
    let id = hex_id(surface_id);
    env.push(("TERMMESH_SURFACE_ID".to_string(), id.clone()));
    env.push(("CMUX_SURFACE_ID".to_string(), id));
    env
}

/// `PREFERRED_TERM` when this machine can describe it, else the floor.
///
/// Naming a terminal the machine has no terminfo entry for is worse than
/// naming a plainer one: every curses program fails to start rather than
/// merely losing a capability.
fn resolve_term() -> String {
    if terminfo_entry_exists(PREFERRED_TERM) {
        PREFERRED_TERM.to_string()
    } else {
        FALLBACK_TERM.to_string()
    }
}

/// Whether a compiled terminfo entry for `name` is installed.
///
/// Checks the directories terminfo is conventionally read from rather than
/// linking ncurses for one lookup. Both layouts are searched: `x/xterm-...`
/// on most systems, and the hashed `78/xterm-...` used on macOS.
fn terminfo_entry_exists(name: &str) -> bool {
    let Some(first) = name.chars().next() else {
        return false;
    };
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Ok(dir) = std::env::var("TERMINFO") {
        roots.push(PathBuf::from(dir));
    }
    if let Ok(home) = std::env::var("HOME") {
        roots.push(PathBuf::from(home).join(".terminfo"));
    }
    roots.extend(
        [
            "/usr/share/terminfo",
            "/lib/terminfo",
            "/etc/terminfo",
            "/usr/lib/terminfo",
            "/usr/local/share/terminfo",
        ]
        .iter()
        .map(PathBuf::from),
    );

    let letter = first.to_string();
    let hashed = format!("{:x}", first as u32);
    roots.iter().any(|root| {
        root.join(&letter).join(name).exists() || root.join(&hashed).join(name).exists()
    })
}

fn hex_id(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
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

/// Pick the login shell for a new pane, most-specific first: the process
/// `$SHELL` (`env_shell`) when usable, then the account's `/etc/passwd`
/// login shell (`passwd_shell`), then `/bin/bash`, then `/bin/sh`. The
/// final `/bin/sh` fallthrough is unconditional — POSIX guarantees its
/// presence, and a broken pane beats a spawn that never happens.
///
/// The passwd fallback matters when the daemon inherited no usable `$SHELL`
/// — systemd units and non-login SSH often carry no `SHELL` at all — but the
/// account is `chsh`-ed to a real shell (zsh/fish). Without it such hosts
/// silently drop to `/bin/bash` or `/bin/sh` even though the login shell is
/// zsh. Both candidates are still gated by `is_usable_shell`, so a
/// nologin/false passwd entry is skipped like any other blocker.
pub(crate) fn resolve_login_shell(env_shell: Option<&str>, passwd_shell: Option<&str>) -> String {
    for candidate in [env_shell, passwd_shell].into_iter().flatten() {
        if is_usable_shell(candidate) {
            return candidate.to_string();
        }
    }
    if is_usable_shell("/bin/bash") {
        return "/bin/bash".to_string();
    }
    "/bin/sh".to_string()
}

/// The current user's login shell from the passwd database (`pw_shell`),
/// used as a fallback when the daemon process inherited no usable `$SHELL`.
/// Returns `None` on any lookup failure or an empty shell field. Uses the
/// thread-safe `getpwuid_r` since the daemon spawns panes off many threads.
fn passwd_login_shell() -> Option<String> {
    use std::ffi::CStr;
    // Safety: standard getpwuid_r idiom — a zeroed `passwd` out-param plus a
    // caller-owned byte buffer that backs its string fields. We copy
    // `pw_shell` into an owned String before `buf` is dropped, so no pointer
    // outlives its backing storage.
    unsafe {
        let uid = libc::getuid();
        let mut buf_len = match libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX) {
            n if n > 0 => n as usize,
            _ => 1024,
        };
        let mut pwd: libc::passwd = std::mem::zeroed();
        loop {
            let mut buf = vec![0u8; buf_len];
            let mut result: *mut libc::passwd = std::ptr::null_mut();
            let rc = libc::getpwuid_r(
                uid,
                &mut pwd,
                buf.as_mut_ptr() as *mut libc::c_char,
                buf.len(),
                &mut result,
            );
            // ERANGE = buffer too small; grow and retry up to a sane ceiling.
            if rc == libc::ERANGE && buf_len < (1 << 20) {
                buf_len *= 2;
                continue;
            }
            if rc != 0 || result.is_null() || pwd.pw_shell.is_null() {
                return None;
            }
            let shell = CStr::from_ptr(pwd.pw_shell).to_str().ok()?.to_string();
            return if shell.is_empty() { None } else { Some(shell) };
        }
    }
}

/// `<shell> -l` command line for a new pane, shared by the startup
/// fallback surface and split/new-tab spawns.
/// The login shell, phrased so that `sh -c` replaces itself with it instead of
/// staying alive as a parent.
///
/// Without `exec` a pane is two processes — the `sh` that was asked to start a
/// shell, and the shell — and the one we hold the pid of is the wrapper, which
/// never leaves the directory it started in. Anything asking the OS where this
/// pane is (see [`PtySurface::current_cwd`]) would read the wrapper and always
/// answer with the spawn directory.
pub(crate) fn login_shell_cmd() -> String {
    let passwd_shell = passwd_login_shell();
    let shell = resolve_login_shell(
        std::env::var("SHELL").ok().as_deref(),
        passwd_shell.as_deref(),
    );
    format!("exec {shell} -l")
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

    /// Winsize arbitration: with several attachers the PTY is sized to the
    /// per-axis minimum (tmux behaviour), and a departing attacher's request
    /// is dropped so the survivors get their grid back. Requester 1 asks for
    /// a wide-short grid and requester 2 for a narrow-tall one, so the min
    /// is a mix of both axes — proving cols and rows arbitrate independently.
    #[tokio::test]
    async fn winsize_arbitrates_min_across_attachers() {
        let surface = cat_surface();
        let size = |s: &PtySurface| {
            (
                s.cols.load(Ordering::Relaxed) as u16,
                s.rows.load(Ordering::Relaxed) as u16,
            )
        };

        surface.request_size(1, 120, 30).expect("first request");
        assert_eq!(size(&surface), (120, 30), "sole attacher gets its size");

        surface.request_size(2, 80, 40).expect("second request");
        assert_eq!(size(&surface), (80, 30), "per-axis min of both requests");

        // The smaller-column attacher leaves → survivor gets its grid back.
        surface.drop_size_request(2);
        assert_eq!(size(&surface), (120, 30), "survivor size restored");

        // Unknown requester is a no-op; last attacher leaving keeps the size.
        surface.drop_size_request(99);
        surface.drop_size_request(1);
        assert_eq!(size(&surface), (120, 30), "last size persists when empty");
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

    /// R1 (peer-relay-bulk-loss): `PtySurface::replay_snapshot_from` is a
    /// thin lock-and-delegate wrapper over `ReplayBuffer::snapshot_from`
    /// (exhaustively tested above at the `ReplayBuffer` level) — this
    /// closes the gap by exercising the public surface entry point a
    /// real `AttachSurface` resume path actually calls, on a real
    /// `PtySurface` (same pattern as the `modes` tests above: reach past
    /// the PTY and manipulate the private `replay` buffer directly, since
    /// no PTY I/O is needed to prove the cut behavior).
    #[tokio::test]
    async fn replay_snapshot_from_on_a_real_surface_cuts_at_the_resume_point() {
        let surface = cat_surface();
        {
            let mut replay = surface.replay.lock().unwrap();
            replay.push(PtyChunk {
                seq: 0,
                bytes: b"hello ".to_vec(),
            });
            replay.push(PtyChunk {
                seq: 6,
                bytes: b"world".to_vec(),
            });
        }

        // from_seq == 0 (no resume) still returns everything.
        assert_eq!(surface.replay_snapshot().len(), 2);
        assert_eq!(surface.replay_snapshot_from(0), surface.replay_snapshot());

        // A resume point inside the buffered range replays only what the
        // client hasn't already seen.
        assert_eq!(
            surface.replay_snapshot_from(6),
            vec![PtyChunk {
                seq: 6,
                bytes: b"world".to_vec(),
            }]
        );

        // Mid-chunk resume trims the straddling chunk instead of resending
        // whole chunks the client is already partway through.
        assert_eq!(
            surface.replay_snapshot_from(8),
            vec![PtyChunk {
                seq: 8,
                bytes: b"rld".to_vec(),
            }]
        );

        // Fully caught up: nothing left to replay.
        assert!(surface.replay_snapshot_from(11).is_empty());
    }

    /// `current_byte_seq()` is what `AttachResult.initial_seq` falls back to
    /// when the replay ring is empty (fresh surface, nothing buffered yet)
    /// — it must track real PTY output as it happens, not just report the
    /// zero it starts at.
    #[tokio::test]
    async fn current_byte_seq_reflects_live_pty_output() {
        let surface = cat_surface();
        assert_eq!(
            surface.current_byte_seq(),
            0,
            "fresh surface has produced nothing yet"
        );

        surface.write_all(b"ping\n").expect("write to /bin/cat's pty");

        // /bin/cat under a PTY echoes the write back on its output side;
        // wait for the reader task to observe it and advance byte_seq.
        let advanced = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if surface.current_byte_seq() > 0 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await;
        assert!(
            advanced.is_ok(),
            "byte_seq must advance once cat echoes the write"
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
        // No passwd candidate: pure env → bash → sh chain (systemd/no-SHELL).
        let assert_falls_back = |candidate: Option<&str>| {
            let result = resolve_login_shell(candidate, None);
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
        assert_eq!(resolve_login_shell(Some("/bin/sh"), None), "/bin/sh");
    }

    #[test]
    fn login_shell_uses_passwd_when_env_absent_or_blocked() {
        // /bin/sh is the one shell universally present in CI/minimal hosts,
        // so use it as the stand-in for "the account's chsh-ed login shell".
        let passwd = Some("/bin/sh");
        // SHELL unset (systemd/non-login SSH) → fall through to passwd shell
        // instead of bash. This is the exact bug this fallback fixes.
        assert_eq!(resolve_login_shell(None, passwd), "/bin/sh");
        // SHELL is a login blocker (service account) → passwd shell still wins.
        assert_eq!(resolve_login_shell(Some("/usr/sbin/nologin"), passwd), "/bin/sh");
        // A usable $SHELL still takes precedence over passwd.
        assert_eq!(resolve_login_shell(Some("/bin/sh"), Some("/no/such/shell")), "/bin/sh");
        // A blocked/nonexistent passwd shell is skipped like any other → bash|sh.
        let both_bad = resolve_login_shell(None, Some("/usr/sbin/nologin"));
        assert!(matches!(both_bad.as_str(), "/bin/bash" | "/bin/sh"), "got {both_bad:?}");
    }

    // --- Container-only end-to-end checks (see scripts/zsh-login-shell-test/) ---
    //
    // These exercise the REAL `getpwuid_r` path, so they only pass on a host
    // whose account is `chsh`-ed to a known shell. They are `#[ignore]`d so
    // ordinary `cargo test` skips them; the zsh container harness runs them
    // with `--ignored` and `EXPECT_PASSWD_SHELL` pointing at the account shell.

    /// The passwd fallback returns the account's actual `/etc/passwd` login
    /// shell. Set `EXPECT_PASSWD_SHELL` to that path (e.g. `/usr/bin/zsh`).
    #[test]
    #[ignore = "requires a host/container with a known passwd login shell"]
    fn passwd_shell_reads_account_login_shell() {
        let expect = std::env::var("EXPECT_PASSWD_SHELL")
            .expect("set EXPECT_PASSWD_SHELL to the account's /etc/passwd login shell");
        assert_eq!(
            passwd_login_shell().as_deref(),
            Some(expect.as_str()),
            "getpwuid_r should report the account's chsh-ed login shell"
        );
    }

    /// With `$SHELL` removed (the systemd / non-login-SSH case), the pane
    /// login command must resolve to the passwd shell — not silently fall to
    /// bash/sh. Run under `env -u SHELL` with `EXPECT_PASSWD_SHELL` set.
    #[test]
    #[ignore = "requires SHELL unset + a passwd login shell; run in the zsh container"]
    fn login_shell_cmd_uses_passwd_when_shell_env_absent() {
        let expect = std::env::var("EXPECT_PASSWD_SHELL")
            .expect("set EXPECT_PASSWD_SHELL to the account's /etc/passwd login shell");
        assert!(
            std::env::var_os("SHELL").is_none(),
            "run this test with `env -u SHELL` so getpwuid_r is the only source"
        );
        assert_eq!(login_shell_cmd(), format!("exec {expect} -l"));
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

    /// The whole point of reading cwd from the OS: it has to follow a `cd`.
    /// Reporting the spawn directory forever is the bug this replaced, and
    /// that bug passes any assertion that only checks the starting value.
    #[tokio::test]
    async fn current_cwd_follows_the_shell_into_a_new_directory() {
        let start = tempfile::tempdir().unwrap();
        let moved_to = tempfile::tempdir().unwrap();
        // Resolve both sides: macOS hands out /var/... symlinks into /private.
        let expected = std::fs::canonicalize(moved_to.path()).unwrap();

        let surface = PtySurface::spawn(
            surface_id_from_name("cwd-follows-test"),
            "sh".into(),
            "/bin/sh",
            &[],
            80,
            24,
            Some(start.path().to_str().unwrap()),
        )
        .expect("spawn /bin/sh");

        surface
            .write_all(format!("cd {}\n", expected.display()).as_bytes())
            .expect("write cd");

        // The shell chdir()s on its own schedule, so poll rather than sleep a
        // fixed amount: fast when it is prompt, still correct when it is slow.
        let mut observed = String::new();
        for i in 0..100 {
            observed = surface.current_cwd();
            if i < 4 || i % 25 == 0 {
                let c = surface.child.lock().unwrap();
                eprintln!(
                    "PROBE i={i} state={:?} raw={:?} observed={:?}",
                    c.state,
                    super::process_cwd(c.pid),
                    observed
                );
            }
            if observed == expected.to_string_lossy() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        eprintln!("PROBE expected={:?} spawn_cwd={:?}", expected, surface.cwd);
        assert_eq!(observed, expected.to_string_lossy());
        // The spawn directory is what the old code would have reported, so
        // stating it separately makes the regression unmistakable.
        assert_ne!(observed, surface.cwd);
    }

    /// Panes are not spawned as a bare shell — they go through `sh -c`, which
    /// is the case the test above does not reach. If that `sh` stays alive as a
    /// parent then the pid we hold is the wrapper's, and a wrapper never
    /// leaves the directory it started in no matter where the shell goes.
    #[tokio::test]
    async fn current_cwd_follows_the_shell_started_through_a_wrapper() {
        assert!(
            login_shell_cmd().starts_with("exec "),
            "the login shell must replace the wrapper, not run under it"
        );

        let start = tempfile::tempdir().unwrap();
        let moved_to = tempfile::tempdir().unwrap();
        let expected = std::fs::canonicalize(moved_to.path()).unwrap();

        // Same shape as a real pane: /bin/sh -c "exec <shell>".
        let surface = PtySurface::spawn(
            surface_id_from_name("cwd-wrapper-test"),
            "sh".into(),
            "/bin/sh",
            &["-c", "exec /bin/sh"],
            80,
            24,
            Some(start.path().to_str().unwrap()),
        )
        .expect("spawn wrapped /bin/sh");

        surface
            .write_all(format!("cd {}\n", expected.display()).as_bytes())
            .expect("write cd");

        let mut observed = String::new();
        for _ in 0..100 {
            observed = surface.current_cwd();
            if observed == expected.to_string_lossy() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert_eq!(observed, expected.to_string_lossy());
    }

    /// The regression this exists for: a pane inherited the daemon's own
    /// environment, which under systemd has no `TERM` at all. A shell with no
    /// `TERM` cannot tell what its terminal supports, and an agent deciding
    /// how to raise a notification concludes it supports none.
    #[tokio::test]
    async fn a_pane_is_told_what_terminal_it_is_attached_to() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("env.txt");
        let surface = PtySurface::spawn(
            surface_id_from_name("env-test"),
            "sh".into(),
            "/bin/sh",
            // Writes what it was given, then stays alive: `spawn` refuses a
            // child that has already exited by the time it checks.
            &[
                "-c",
                &format!(
                    "{{ printenv TERM; printenv TERM_PROGRAM; printenv COLORTERM; }} > {}; exec cat",
                    out.display()
                ),
            ],
            80,
            24,
            None,
        )
        .expect("spawn");

        for _ in 0..100 {
            if std::fs::read_to_string(&out).is_ok_and(|c| c.lines().count() >= 3) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        drop(surface);

        let written = std::fs::read_to_string(&out).expect("the pane wrote its environment");
        let lines: Vec<&str> = written.lines().collect();
        assert_eq!(lines.len(), 3, "every variable must be set, got {written:?}");
        assert!(
            lines[0] == PREFERRED_TERM || lines[0] == FALLBACK_TERM,
            "TERM must name a terminal this machine can describe, got {:?}",
            lines[0]
        );
        assert_eq!(lines[1], "ghostty");
        assert_eq!(lines[2], "truecolor");
    }

    /// Inherited, not replaced: `PATH` and `HOME` are where the pane's shell
    /// comes from, and losing them would break it far louder than a missing
    /// `TERM` ever did.
    #[tokio::test]
    async fn a_pane_keeps_the_environment_it_inherited() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("path.txt");
        let surface = PtySurface::spawn(
            surface_id_from_name("env-inherit-test"),
            "sh".into(),
            "/bin/sh",
            &[
                "-c",
                &format!("printenv PATH > {}; exec cat", out.display()),
            ],
            80,
            24,
            None,
        )
        .expect("spawn");

        for _ in 0..100 {
            if out.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        drop(surface);

        let written = std::fs::read_to_string(&out).unwrap_or_default();
        assert!(!written.trim().is_empty(), "PATH must survive");
    }

    /// Naming a terminal the machine has no terminfo for is worse than naming
    /// a plainer one: curses programs fail to start rather than lose a
    /// capability. So whatever is chosen must actually be installed.
    #[test]
    fn the_chosen_term_is_one_this_machine_can_describe() {
        let term = resolve_term();
        assert!(
            terminfo_entry_exists(&term),
            "resolved TERM {term:?} has no terminfo entry here"
        );
    }

    #[test]
    fn an_unknown_terminal_is_not_claimed_to_exist() {
        assert!(!terminfo_entry_exists("term-mesh-no-such-terminal-xyz"));
    }

    // -- ReplayBuffer::snapshot_from -----------------------------------

    fn chunk(seq: u64, bytes: &[u8]) -> PtyChunk {
        PtyChunk {
            seq,
            bytes: bytes.to_vec(),
        }
    }

    /// Three chunks covering seq ranges [0,4) [4,8) [8,12).
    fn three_chunk_buffer() -> ReplayBuffer {
        let mut buf = ReplayBuffer::default();
        buf.push(chunk(0, b"aaaa"));
        buf.push(chunk(4, b"bbbb"));
        buf.push(chunk(8, b"cccc"));
        buf
    }

    #[test]
    fn snapshot_from_empty_buffer_is_empty() {
        let buf = ReplayBuffer::default();
        assert!(buf.snapshot_from(0).is_empty());
        assert!(buf.snapshot_from(999).is_empty());
    }

    #[test]
    fn snapshot_from_zero_matches_full_snapshot() {
        let buf = three_chunk_buffer();
        assert_eq!(buf.snapshot_from(0), buf.snapshot());
    }

    #[test]
    fn snapshot_from_exact_chunk_boundary_drops_earlier_chunks() {
        let buf = three_chunk_buffer();
        let out = buf.snapshot_from(4);
        assert_eq!(out, vec![chunk(4, b"bbbb"), chunk(8, b"cccc")]);
    }

    #[test]
    fn snapshot_from_mid_chunk_trims_the_straddling_chunk() {
        let buf = three_chunk_buffer();
        let out = buf.snapshot_from(6);
        assert_eq!(out, vec![chunk(6, b"bb"), chunk(8, b"cccc")]);
    }

    #[test]
    fn snapshot_from_last_byte_returns_only_the_tail_byte() {
        let buf = three_chunk_buffer();
        let out = buf.snapshot_from(11);
        assert_eq!(out, vec![chunk(11, b"c")]);
    }

    /// `from_seq == end` (one past the last buffered byte) means "caller is
    /// fully caught up" — a legitimate in-range request with nothing new to
    /// send, not a fallback case.
    #[test]
    fn snapshot_from_caught_up_point_is_empty_not_a_fallback() {
        let buf = three_chunk_buffer();
        assert!(buf.snapshot_from(12).is_empty());
    }

    /// Older than anything the ring still holds: the gap was already
    /// evicted, so an exact resume is impossible. Falls back to resending
    /// everything still buffered rather than silently dropping bytes.
    #[test]
    fn snapshot_from_before_ring_start_falls_back_to_full_snapshot() {
        // A ring that has evicted its earliest bytes starts later than 0.
        let mut evicted = ReplayBuffer::default();
        evicted.push(chunk(100, b"dddd"));
        evicted.push(chunk(104, b"eeee"));
        let out = evicted.snapshot_from(50);
        assert_eq!(
            out,
            evicted.snapshot(),
            "from_seq older than the ring's oldest chunk must fall back to full snapshot"
        );
    }

    /// Newer than anything ever buffered (seq-space mismatch or a stale
    /// caller): also out of range, also falls back rather than returning
    /// nothing.
    #[test]
    fn snapshot_from_past_the_end_falls_back_to_full_snapshot() {
        let buf = three_chunk_buffer();
        let out = buf.snapshot_from(999);
        assert_eq!(out, buf.snapshot());
    }

    /// Defends the saturating arithmetic: a chunk whose seq sits near
    /// `u64::MAX` must not panic on overflow, and must still cut correctly.
    /// Real byte_seq counters never get remotely this large (it would take
    /// exabytes of PTY output), but the function must not assume that.
    #[test]
    fn snapshot_from_near_u64_max_does_not_panic_and_cuts_correctly() {
        let near_max = u64::MAX - 4;
        let mut buf = ReplayBuffer::default();
        buf.push(chunk(near_max, b"wxyz"));

        // In range, mid-chunk: still slices correctly right up to the edge.
        let out = buf.snapshot_from(near_max + 2);
        assert_eq!(out, vec![chunk(near_max + 2, b"yz")]);

        // Exactly at the end (one past the last byte) saturates instead of
        // overflowing, and correctly reads as "caught up" (empty), not a
        // fallback.
        let end = near_max.saturating_add(4);
        assert_eq!(end, u64::MAX);
        assert!(buf.snapshot_from(end).is_empty());

        // Past `u64::MAX` cannot exist as a `u64` value, so `u64::MAX`
        // itself is the highest possible from_seq — already covered above.
        // A from_seq before the chunk still trims normally.
        let out = buf.snapshot_from(near_max);
        assert_eq!(out, vec![chunk(near_max, b"wxyz")]);
    }

    // -- ReplayBuffer::snapshot_tail -----------------------------------

    #[test]
    fn snapshot_tail_empty_buffer_is_empty() {
        let buf = ReplayBuffer::default();
        assert!(buf.snapshot_tail(0).is_empty());
        assert!(buf.snapshot_tail(64 * 1024).is_empty());
    }

    /// Budget larger than everything buffered: the tail IS the whole ring,
    /// so a small surface still replays in full.
    #[test]
    fn snapshot_tail_budget_above_total_returns_full_snapshot() {
        let buf = three_chunk_buffer();
        assert_eq!(buf.snapshot_tail(64 * 1024), buf.snapshot());
    }

    /// Budget that fits exactly two of the three chunks: the OLDEST is
    /// dropped, not the newest — this is a tail, not a head.
    #[test]
    fn snapshot_tail_drops_oldest_chunks_first() {
        let buf = three_chunk_buffer();
        let out = buf.snapshot_tail(8);
        assert_eq!(out, vec![chunk(4, b"bbbb"), chunk(8, b"cccc")]);
    }

    /// A budget that would only partially cover a chunk does NOT split it:
    /// chunks are whole PTY reads, so the cut lands on the boundary below.
    #[test]
    fn snapshot_tail_cuts_on_chunk_boundaries_never_mid_chunk() {
        let buf = three_chunk_buffer();
        // 6 bytes of budget spans all of "cccc" plus half of "bbbb"; the
        // half chunk is dropped whole rather than sliced.
        let out = buf.snapshot_tail(6);
        assert_eq!(out, vec![chunk(8, b"cccc")]);
    }

    /// The newest chunk is kept even when it alone busts the budget — a
    /// blank pane is strictly worse than one oversized replay.
    #[test]
    fn snapshot_tail_always_keeps_the_newest_chunk() {
        let buf = three_chunk_buffer();
        assert_eq!(buf.snapshot_tail(0), vec![chunk(8, b"cccc")]);
        assert_eq!(buf.snapshot_tail(1), vec![chunk(8, b"cccc")]);
    }

    /// The whole point of the split: the ring stays sized for resume while a
    /// fresh attach only ever sees `FRESH_ATTACH_REPLAY_BYTES`. A surface
    /// that produced far more than that must not replay all of it on open.
    #[test]
    fn snapshot_tail_bounds_a_ring_far_larger_than_the_fresh_budget() {
        let mut buf = ReplayBuffer::default();
        let chunk_len = 4 * 1024usize;
        let chunk_count = 64; // 256 KiB total — 4x the fresh budget
        for i in 0..chunk_count {
            buf.push(chunk(
                (i * chunk_len) as u64,
                &vec![b'x'; chunk_len],
            ));
        }
        let total: usize = buf.snapshot().iter().map(|c| c.bytes.len()).sum();
        assert_eq!(total, chunk_count * chunk_len);

        let tail = buf.snapshot_tail(FRESH_ATTACH_REPLAY_BYTES);
        let tail_bytes: usize = tail.iter().map(|c| c.bytes.len()).sum();
        assert!(
            tail_bytes <= FRESH_ATTACH_REPLAY_BYTES,
            "fresh-attach replay must stay within its budget, got {tail_bytes}"
        );
        assert!(tail_bytes > 0, "fresh attach must not replay nothing");
        // And it is the NEWEST bytes: the last chunk of the ring is the last
        // chunk of the tail.
        assert_eq!(tail.last(), buf.snapshot().last());
    }

    // -- ScreenModel / screen_snapshot -----------------------------------

    /// Round-trip: feeding a snapshot into a fresh parser must reproduce
    /// the screen. This is the core contract the whole grid-snapshot design
    /// stands on — if state_formatted() can't rebuild its own screen, a
    /// viewer can't either.
    #[test]
    fn screen_model_roundtrip_reproduces_contents() {
        let mut model = ScreenModel::new(80, 24);
        model.feed(b"\x1b[31mred\x1b[m plain\r\nline2 \x1b[1mbold\x1b[m\r\n", 0);
        model.feed(b"\x1b[5;10Hcursor-positioned", 0);

        let mut reparsed = vt100::Parser::new(24, 80, 0);
        let vt = model.parser.screen();
        reparsed.process(&vt.state_formatted());

        assert_eq!(
            reparsed.screen().contents(),
            vt.contents(),
            "state_formatted must reproduce the exact screen contents"
        );
        assert_eq!(reparsed.screen().cursor_position(), vt.cursor_position());
    }

    /// An escape sequence split across two feeds (the 4096-byte read
    /// boundary case) must parse as if it arrived whole — vte is a
    /// streaming state machine, and this pins that property so a future
    /// batching layer can't accidentally break it.
    #[test]
    fn screen_model_survives_escape_split_across_feeds() {
        let mut split = ScreenModel::new(80, 24);
        // Split an SGR + text mid-sequence: ESC [ 3 | 1 m red
        split.feed(b"\x1b[3", 0);
        split.feed(b"1mred\x1b[m", 0);

        let mut whole = ScreenModel::new(80, 24);
        whole.feed(b"\x1b[31mred\x1b[m", 0);

        assert_eq!(
            split.parser.screen().state_formatted(),
            whole.parser.screen().state_formatted(),
            "chunk-split escape must render identically to the unsplit form"
        );
    }

    /// Alt-screen: the snapshot must carry ESC[?1049h ahead of vt100's own
    /// output, or the viewer paints the TUI into its primary screen and the
    /// app's later ?1049l no-ops (the TUI never goes away).
    #[tokio::test]
    async fn screen_snapshot_prefixes_alt_screen_switch() {
        let surface = PtySurface::spawn(
            surface_id_from_name("alt-snap"),
            "alt-snap".into(),
            "/bin/sh",
            &["-c", "printf '\\033[?1049halt-content'; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn alt-snap surface");

        // Poll until the reader has fed the alt-screen switch through.
        let mut saw_alt = false;
        for _ in 0..100 {
            if let Some((bytes, _)) = surface.screen_snapshot() {
                if bytes.starts_with(b"\x1b[?1049h")
                    && bytes.windows(11).any(|w| w == b"alt-content")
                {
                    saw_alt = true;
                    break;
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        surface.hangup();
        assert!(
            saw_alt,
            "snapshot of an alt-screen surface must start with ESC[?1049h and contain its content"
        );
    }

    /// The watermark must equal the END seq of the last fed chunk, and the
    /// snapshot/seq pair must be read atomically (both under one lock).
    #[tokio::test]
    async fn screen_snapshot_watermark_matches_byte_seq() {
        const MARKER: &[u8] = b"WATERMARK-SYNC";
        let surface = PtySurface::spawn(
            surface_id_from_name("watermark"),
            "watermark".into(),
            "/bin/sh",
            &["-c", "printf WATERMARK-SYNC; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn watermark surface");

        let mut synced = false;
        for _ in 0..100 {
            let (snapshot, fed_through) = match surface.screen_snapshot() {
                Some(pair) => pair,
                None => continue,
            };
            let contains = snapshot
                .windows(MARKER.len())
                .any(|w| w == MARKER);
            if contains && fed_through == surface.current_byte_seq() {
                synced = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        surface.hangup();
        assert!(
            synced,
            "once output settles, fed_through must equal the surface's byte_seq"
        );
    }

    /// Stress (the done_criteria's 10MB/s case, expressed as throughput):
    /// feeding 10 MB through the model in read-sized chunks must complete
    /// promptly — the per-chunk lock hold is a parse, not I/O, and nothing
    /// about it may block or accumulate.
    #[test]
    fn screen_model_stress_ten_megabytes_of_flood() {
        let mut model = ScreenModel::new(120, 40);
        let chunk = vec![b'x'; READ_BUF_SIZE];
        let start = std::time::Instant::now();
        let mut fed = 0u64;
        while fed < 10 * 1024 * 1024 {
            model.feed(&chunk, fed + chunk.len() as u64);
            fed += chunk.len() as u64;
        }
        let elapsed = start.elapsed();
        // Generous bound on purpose: this asserts "a flood terminates
        // promptly", not a benchmark number — under a full parallel test
        // run on a loaded box (observed on the Linux peer) 5s flaked while
        // the single-run time stayed ~100ms.
        assert!(
            elapsed < std::time::Duration::from_secs(60),
            "10MB of plain flood must terminate promptly, took {elapsed:?}"
        );
        // The screen is still coherent after the flood.
        assert_eq!(model.fed_through, fed);
        let rendered = model.parser.screen().state_formatted();
        assert!(!rendered.is_empty());
    }

    /// Scrollback window rendering: content that scrolled off the live
    /// screen must come back at an offset, clamped at the oldest retained
    /// row, and the browse must leave the live screen untouched.
    #[tokio::test]
    async fn scrollback_render_returns_scrolled_out_content_and_clamps() {
        let surface = PtySurface::spawn(
            surface_id_from_name("sb-render"),
            "sb-render".into(),
            "/bin/sh",
            &["-c", "for i in $(seq 1 40); do echo LINE-$i; done; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn sb-render surface");

        // Wait until the tail line has been fed through the screen model.
        let mut ready = false;
        for _ in 0..150 {
            if let Some((snap, _)) = surface.screen_snapshot() {
                if snap.windows(7).any(|w| w == b"LINE-40") {
                    ready = true;
                    break;
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(ready, "seq output never reached the screen model");

        // 40 lines + prompt on a 24-row screen => 17+ rows of scrollback.
        // A window 10 rows up must show lines the live screen no longer
        // holds, as a full replacement render (clear+home preamble).
        let (ansi, effective, _at_top, total) =
            surface.scrollback_render(10).expect("render");
        assert_eq!(effective, 10);
        assert!(total >= 10, "expected >=10 rows of scrollback, got {total}");
        assert!(ansi.windows(6).any(|w| w == b"\x1b[H\x1b[J".as_slice())
            || ansi.windows(6).any(|w| w == b"\x1b[J\x1b[H".as_slice())
            || ansi.starts_with(b"\x1b[m"),
            "scrollback window must be a full replacement render");
        // The window shows OLDER lines than the live bottom.
        assert!(
            ansi.windows(7).any(|w| w == b"LINE-30".as_slice())
                || ansi.windows(7).any(|w| w == b"LINE-25".as_slice()),
            "scrollback window must contain scrolled-out lines"
        );

        // Clamp: asking far past the retained history reports at_top and an
        // effective offset no larger than the total.
        let (_, effective, at_top, total2) =
            surface.scrollback_render(1_000_000).expect("render");
        assert!(at_top);
        assert!(effective <= total2);

        // Atomicity/restore: the browse must not disturb the live screen.
        let (snap_after, _) = surface.screen_snapshot().expect("snapshot");
        assert!(
            snap_after.windows(7).any(|w| w == b"LINE-40"),
            "live screen must be untouched after a scrollback browse"
        );
        surface.hangup();
    }

    /// Paging regression guard (live-observed 2026-07-22): three successive
    /// browse windows at growing offsets must render three DIFFERENT slices
    /// of history, each older than the last. Catches any offset that gets
    /// applied but not rendered (window content identical to live screen).
    #[tokio::test]
    async fn scrollback_render_paging_returns_distinct_older_windows() {
        let surface = PtySurface::spawn(
            surface_id_from_name("sb-paging"),
            "sb-paging".into(),
            "/bin/sh",
            &["-c", "for i in $(seq 1 300); do echo SBLINE-$i; done; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn sb-paging surface");

        let mut ready = false;
        for _ in 0..250 {
            if let Some((snap, _)) = surface.screen_snapshot() {
                if snap.windows(10).any(|w| w == b"SBLINE-300") {
                    ready = true;
                    break;
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(ready, "seq output never reached the screen model");

        // Highest SBLINE-<n> number present in a render — a strictly
        // decreasing sequence across growing offsets proves each window is
        // genuinely older, not a re-render of the live screen.
        fn max_line_no(ansi: &[u8]) -> u32 {
            let text = String::from_utf8_lossy(ansi);
            text.split("SBLINE-")
                .skip(1)
                .filter_map(|rest| {
                    rest.bytes()
                        .take_while(|b| b.is_ascii_digit())
                        .fold(None, |acc: Option<u32>, b| {
                            Some(acc.unwrap_or(0) * 10 + (b - b'0') as u32)
                        })
                })
                .max()
                .unwrap_or(0)
        }

        let mut prev_max = u32::MAX;
        for offset in [32u32, 64, 96] {
            let (ansi, effective, at_top, _total) =
                surface.scrollback_render(offset).expect("render");
            assert_eq!(effective, offset, "offset {offset} must apply verbatim");
            assert!(!at_top, "offset {offset} is nowhere near 300 lines of history");
            let this_max = max_line_no(&ansi);
            assert!(
                this_max > 0,
                "offset {offset}: window contains no SBLINE at all"
            );
            assert!(
                this_max < prev_max,
                "offset {offset}: window max SBLINE-{this_max} not older than \
                 previous window's SBLINE-{prev_max} — offset applied but not rendered"
            );
            prev_max = this_max;
        }
        // And every window is older than the live bottom.
        assert!(prev_max < 300);
        surface.hangup();
    }

    /// Alt-screen: scrollback browsing is meaningless there (the alt grid
    /// never accumulates scrollback — same rule as tmux), so the render is
    /// empty and terminal.
    #[tokio::test]
    async fn scrollback_render_on_alt_screen_is_empty_and_terminal() {
        let surface = PtySurface::spawn(
            surface_id_from_name("sb-alt"),
            "sb-alt".into(),
            "/bin/sh",
            &["-c", "printf '\\033[?1049halt'; sleep 5"],
            80,
            24,
            None,
        )
        .expect("spawn sb-alt surface");
        let mut on_alt = false;
        for _ in 0..100 {
            if let Some((snap, _)) = surface.screen_snapshot() {
                if snap.starts_with(b"\x1b[?1049h") {
                    on_alt = true;
                    break;
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(on_alt);
        let (ansi, effective, at_top, _total) =
            surface.scrollback_render(5).expect("render");
        assert!(ansi.is_empty());
        assert_eq!(effective, 0);
        assert!(at_top);
        surface.hangup();
    }

    /// Adversarial: a poisoned screen lock must degrade to None (callers
    /// fall back to the byte-replay path), never panic the attach handler.
    #[tokio::test]
    async fn screen_snapshot_poisoned_lock_returns_none() {
        let surface = PtySurface::spawn(
            surface_id_from_name("poison"),
            "poison".into(),
            "/bin/cat",
            &[],
            80,
            24,
            None,
        )
        .expect("spawn poison surface");

        // Poison the lock: panic while holding it.
        {
            let surface = surface.clone();
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
                let _guard = surface.screen.lock().unwrap();
                panic!("deliberate poison");
            }));
        }

        assert!(
            surface.screen_snapshot().is_none(),
            "poisoned lock must yield None, not panic"
        );
        // The byte-replay fallback still works.
        let _ = surface.replay_snapshot_fresh();
        surface.hangup();
    }
}
