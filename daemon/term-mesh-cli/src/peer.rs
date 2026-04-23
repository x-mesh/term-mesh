//! Peer-federation client for tm-agent.
//!
//! Phase 2.2b shipped a line-buffered PoC. Phase 2.3B-b.2 adds:
//!   - termios raw mode so each keystroke reaches the remote immediately
//!     (vim, less, etc. behave correctly)
//!   - SIGWINCH → Resize frame so the remote PTY reflows on window resize
//!   - Ctrl-] detach key (line-based Ctrl-D EOF no longer reaches us under
//!     raw mode)
//!   - All outgoing frames serialized through a single writer thread so
//!     SIGWINCH, stdin, and handshake-follow-up writes don't race.

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc};

use peer_proto::v1::envelope::Payload;
use peer_proto::v1::{
    AttachMode, AttachSurface, Auth, Envelope, Goodbye, Hello, Input, ListSurfaces, Resize,
};
use peer_proto::MAX_FRAME_BYTES;
use prost::Message;

const PROTOCOL_VERSION: &str = "1.0.0";
const DEFAULT_COLS: u32 = 80;
const DEFAULT_ROWS: u32 = 24;
/// Ctrl-] — same convention as telnet. One keystroke, no two-step escape.
const DETACH_KEY: u8 = 0x1d;

/// Establish a connection, run the Hello/Auth handshake, and return the
/// stream halves + the running seq counter. Used by both `list_cmd` and
/// `attach_cmd` so their handshake stays in sync.
fn connect_and_authenticate(
    socket_path: &Path,
    emit_banners: bool,
) -> anyhow::Result<(UnixStream, UnixStream, Arc<AtomicU64>)> {
    let stream = UnixStream::connect(socket_path)
        .map_err(|e| anyhow::anyhow!("connect {}: {e}", socket_path.display()))?;
    let read_stream = stream.try_clone()?;
    let mut write_stream = stream;
    let mut read_ref = write_stream.try_clone()?;

    let seq = Arc::new(AtomicU64::new(0));
    let peer_id = random_16_bytes();
    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Hello(Hello {
                protocol_version: PROTOCOL_VERSION.into(),
                peer_id,
                display_name: std::env::var("TERMMESH_PEER_CLIENT_NAME")
                    .unwrap_or_else(|_| "tm-agent-peer".into()),
                capabilities: vec![],
                app_version: env!("CARGO_PKG_VERSION").into(),
            })),
        },
    )?;

    let host_hello = read_envelope(&mut read_ref)?;
    let Some(Payload::Hello(h)) = host_hello.payload else {
        anyhow::bail!("host did not send Hello first");
    };
    if emit_banners {
        eprintln!(
            "[peer] connected to {} ({}), protocol {}",
            h.display_name, h.app_version, h.protocol_version
        );
    }

    let challenge = read_envelope(&mut read_ref)?;
    match challenge.payload {
        Some(Payload::AuthChallenge(_)) => {}
        other => anyhow::bail!("expected AuthChallenge, got {other:?}"),
    }

    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Auth(Auth {
                method: "ssh-passthrough".into(),
                token_id: vec![],
                signature: vec![],
            })),
        },
    )?;

    let auth_result = read_envelope(&mut read_ref)?;
    match auth_result.payload {
        Some(Payload::AuthResult(r)) if r.accepted => {
            if emit_banners {
                eprintln!("[peer] authenticated");
            }
        }
        Some(Payload::AuthResult(r)) => anyhow::bail!("auth rejected: {}", r.reason),
        other => anyhow::bail!("expected AuthResult, got {other:?}"),
    }

    // Both read halves on the same underlying socket; return one pair to the caller.
    drop(read_ref);
    Ok((read_stream, write_stream, seq))
}

fn list_surfaces(
    read_stream: &mut UnixStream,
    write_stream: &mut UnixStream,
    seq: &AtomicU64,
) -> anyhow::Result<Vec<peer_proto::v1::SurfaceInfo>> {
    write_envelope(
        write_stream,
        &Envelope {
            seq: next_seq(seq),
            correlation_id: 0,
            payload: Some(Payload::ListSurfaces(ListSurfaces {})),
        },
    )?;
    let list_reply = read_envelope(read_stream)?;
    match list_reply.payload {
        Some(Payload::SurfaceList(sl)) => Ok(sl.surfaces),
        other => anyhow::bail!("expected SurfaceList, got {other:?}"),
    }
}

pub fn list_cmd(socket_path: &Path) -> anyhow::Result<()> {
    let (mut read_stream, mut write_stream, seq) =
        connect_and_authenticate(socket_path, /* emit_banners */ false)?;
    let surfaces = list_surfaces(&mut read_stream, &mut write_stream, &seq)?;
    if surfaces.is_empty() {
        println!("(no surfaces)");
        return Ok(());
    }
    for s in surfaces {
        let status = if s.attachable { "live" } else { "dead" };
        let branch = if s.branch.is_empty() {
            "-".into()
        } else {
            format!("@{}", s.branch)
        };
        println!(
            "{title:<20} {cols:>3}x{rows:<3}  {status:<4}  {branch:<16}  {cwd}  [{id}]",
            title = s.title,
            cols = s.cols,
            rows = s.rows,
            branch = branch,
            cwd = if s.cwd.is_empty() { "-" } else { s.cwd.as_str() },
            id = hex_short(&s.surface_id),
        );
    }
    Ok(())
}

pub fn attach_cmd(socket_path: &Path, name: Option<&str>) -> anyhow::Result<()> {
    let (mut read_stream_init, mut write_stream, seq) =
        connect_and_authenticate(socket_path, /* emit_banners */ true)?;

    let surfaces = list_surfaces(&mut read_stream_init, &mut write_stream, &seq)?;

    let chosen = match name {
        Some(n) => {
            // Match by exact title OR by ID hex-prefix (e.g. "33e5ce65").
            let n_lower = n.to_ascii_lowercase();
            surfaces
                .iter()
                .find(|s| s.title == n || hex_short(&s.surface_id).starts_with(&n_lower))
                .cloned()
                .ok_or_else(|| {
                    let available: Vec<String> = surfaces
                        .iter()
                        .map(|s| format!("{} [{}]", s.title, hex_short(&s.surface_id)))
                        .collect();
                    anyhow::anyhow!(
                        "surface \"{n}\" not found on host; available: {}",
                        available.join(", ")
                    )
                })?
        }
        None => surfaces
            .first()
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("host reports no attachable surfaces"))?,
    };

    eprintln!(
        "[peer] attaching surface \"{}\" ({}) {}x{}",
        hex_short(&chosen.surface_id),
        chosen.title,
        chosen.cols,
        chosen.rows
    );

    let mut read_stream = read_stream_init;
    let surface_id = chosen.surface_id.clone();

    // ---- attach ----
    let (cols, rows) = term_size().unwrap_or((DEFAULT_COLS, DEFAULT_ROWS));
    write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::AttachSurface(AttachSurface {
                surface_id: surface_id.clone(),
                mode: AttachMode::CoWrite as i32,
                client_cols: cols,
                client_rows: rows,
                resume_from_seq: 0,
            })),
        },
    )?;
    let attach_reply = read_envelope(&mut read_stream)?;
    match attach_reply.payload {
        Some(Payload::AttachResult(r)) if r.accepted => {
            eprintln!("[peer] attached; streaming. Ctrl-] to detach.");
        }
        Some(Payload::AttachResult(r)) => anyhow::bail!("attach rejected: {}", r.reason),
        other => anyhow::bail!("expected AttachResult, got {other:?}"),
    }

    // ---- transition to interactive mode ----

    // Raw mode on stdin (no-op if stdin isn't a TTY, e.g. in tests).
    let _raw_guard = RawModeGuard::enable();

    // Single writer thread so stdin / SIGWINCH / cleanup can all emit frames
    // without locking the stream.
    let (out_tx, out_rx) = mpsc::channel::<Envelope>();
    let writer_handle = std::thread::spawn(move || -> io::Result<()> {
        while let Ok(env) = out_rx.recv() {
            if write_envelope(&mut write_stream, &env).is_err() {
                break;
            }
        }
        let _ = write_stream.shutdown(std::net::Shutdown::Write);
        Ok(())
    });

    // Socket → stdout reader thread.
    let reader_handle = std::thread::spawn(move || -> io::Result<()> {
        let stdout = io::stdout();
        loop {
            let env = match read_envelope(&mut read_stream) {
                Ok(e) => e,
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
                Err(e) => return Err(e),
            };
            match env.payload {
                Some(Payload::PtyData(p)) => {
                    let mut out = stdout.lock();
                    out.write_all(&p.payload)?;
                    out.flush()?;
                }
                Some(Payload::WorkspaceUpdate(wu)) => {
                    if let Some(peer_proto::v1::workspace_update::Kind::Meta(m)) = wu.kind {
                        let branch = if m.branch.is_empty() {
                            String::new()
                        } else {
                            format!(" @{}", m.branch)
                        };
                        let cwd = if m.cwd.is_empty() { "-" } else { m.cwd.as_str() };
                        eprintln!("\r\n[peer] workspace: cwd={cwd}{branch}");
                    }
                }
                Some(Payload::Error(e)) => {
                    eprintln!("\r\n[peer error {}] {}", e.code, e.message);
                    if e.code >= 500 {
                        return Ok(());
                    }
                }
                Some(Payload::Goodbye(g)) => {
                    eprintln!("\r\n[peer] host goodbye: {}", g.reason);
                    return Ok(());
                }
                _ => {}
            }
        }
    });

    // SIGWINCH pipe + processor thread.
    let sigwinch_read_fd = install_sigwinch_pipe()
        .map_err(|e| {
            eprintln!("[peer] SIGWINCH setup failed: {e} — resize events won't propagate");
            e
        })
        .ok();

    let sigwinch_handle = sigwinch_read_fd.map(|fd| {
        let tx = out_tx.clone();
        let id = surface_id.clone();
        let seq = seq.clone();
        std::thread::spawn(move || {
            let mut scratch = [0u8; 16];
            loop {
                // Drain the pipe (one byte per SIGWINCH; merge bursts).
                let n = unsafe {
                    libc::read(fd, scratch.as_mut_ptr() as *mut _, scratch.len())
                };
                if n <= 0 {
                    break;
                }
                if let Some((cols, rows)) = term_size() {
                    let env = Envelope {
                        seq: next_seq(&seq),
                        correlation_id: 0,
                        payload: Some(Payload::Resize(Resize {
                            surface_id: id.clone(),
                            cols,
                            rows,
                            pixel_width: 0,
                            pixel_height: 0,
                        })),
                    };
                    if tx.send(env).is_err() {
                        break;
                    }
                }
            }
        })
    });

    // ---- stdin relay + detach watch ----
    let stdin = io::stdin();
    let mut buf = [0u8; 1024];
    let mut detached = false;
    loop {
        let n = match stdin.lock().read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        if buf[..n].contains(&DETACH_KEY) {
            detached = true;
            break;
        }
        let env = Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Input(Input {
                surface_id: surface_id.clone(),
                kind: Some(peer_proto::v1::input::Kind::Keys(buf[..n].to_vec())),
            })),
        };
        if out_tx.send(env).is_err() {
            break;
        }
    }

    // ---- graceful goodbye ----
    let reason = if detached { "client detach (Ctrl-])" } else { "client stdin EOF" };
    let _ = out_tx.send(Envelope {
        seq: next_seq(&seq),
        correlation_id: 0,
        payload: Some(Payload::Goodbye(Goodbye {
            reason: reason.into(),
        })),
    });

    // Close the SIGWINCH pipe's write end BEFORE dropping out_tx so the
    // sigwinch thread (which holds an out_tx clone and is blocked in
    // libc::read on the pipe's read end) wakes up, drops its clone, and
    // lets the writer thread observe "no more senders".
    let prev_fd = SIGWINCH_PIPE_WRITE.swap(-1, Ordering::Relaxed);
    if prev_fd >= 0 {
        unsafe {
            libc::close(prev_fd);
        }
    }

    drop(out_tx);
    let _ = writer_handle.join();
    let _ = reader_handle.join();
    if let Some(h) = sigwinch_handle {
        let _ = h.join();
    }

    if detached {
        eprintln!("[peer] detached.");
    }
    Ok(())
}

// ── framing (sync) ────────────────────────────────────────────────

fn read_envelope<R: Read>(reader: &mut R) -> io::Result<Envelope> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf);
    if len > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame length {len} exceeds {MAX_FRAME_BYTES}"),
        ));
    }
    let mut buf = vec![0u8; len as usize];
    reader.read_exact(&mut buf)?;
    Envelope::decode(buf.as_slice())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("decode: {e}")))
}

fn write_envelope<W: Write>(writer: &mut W, envelope: &Envelope) -> io::Result<()> {
    let bytes = envelope.encode_to_vec();
    let len = bytes.len();
    if len > MAX_FRAME_BYTES as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame length {len} exceeds {MAX_FRAME_BYTES}"),
        ));
    }
    writer.write_all(&(len as u32).to_le_bytes())?;
    writer.write_all(&bytes)?;
    writer.flush()?;
    Ok(())
}

// ── termios raw-mode guard ────────────────────────────────────────

struct RawModeGuard {
    original: libc::termios,
    applied: bool,
}

impl RawModeGuard {
    fn enable() -> Self {
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::isatty(libc::STDIN_FILENO) } != 1 {
            return RawModeGuard {
                original,
                applied: false,
            };
        }
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return RawModeGuard {
                original,
                applied: false,
            };
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } == 0 {
            RawModeGuard {
                original,
                applied: true,
            }
        } else {
            RawModeGuard {
                original,
                applied: false,
            }
        }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if self.applied {
            unsafe {
                libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &self.original);
            }
        }
    }
}

// ── SIGWINCH self-pipe ────────────────────────────────────────────

/// Write end of the SIGWINCH pipe. Read by the signal handler with atomic
/// load; any value >= 0 is a live fd. AtomicI32 loads are async-signal-safe.
static SIGWINCH_PIPE_WRITE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn sigwinch_handler(_sig: libc::c_int) {
    let fd = SIGWINCH_PIPE_WRITE.load(Ordering::Relaxed);
    if fd < 0 {
        return;
    }
    let buf = [1u8];
    // write(2) is async-signal-safe; ignore errors — the processor thread
    // will just miss one wakeup.
    unsafe {
        libc::write(fd, buf.as_ptr() as *const _, 1);
    }
}

fn install_sigwinch_pipe() -> io::Result<libc::c_int> {
    let mut fds = [0i32; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    for &fd in &fds {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD, 0) };
        if flags >= 0 {
            unsafe {
                libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
    }
    let read_fd = fds[0];
    let write_fd = fds[1];
    SIGWINCH_PIPE_WRITE.store(write_fd, Ordering::Relaxed);

    let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
    sa.sa_sigaction = sigwinch_handler as *const () as libc::sighandler_t;
    unsafe {
        libc::sigemptyset(&mut sa.sa_mask);
    }
    sa.sa_flags = libc::SA_RESTART;

    let rc = unsafe { libc::sigaction(libc::SIGWINCH, &sa, std::ptr::null_mut()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(read_fd)
}

// ── helpers ───────────────────────────────────────────────────────

fn next_seq(seq: &AtomicU64) -> u64 {
    seq.fetch_add(1, Ordering::Relaxed) + 1
}

fn random_16_bytes() -> Vec<u8> {
    let mut out = [0u8; 16];
    let pid = std::process::id() as u128;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mix = (pid << 64) | (now & 0xFFFF_FFFF_FFFF_FFFF);
    out.copy_from_slice(&mix.to_le_bytes());
    out.to_vec()
}

fn hex_short(bytes: &[u8]) -> String {
    let n = bytes.len().min(4);
    bytes[..n].iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(unix)]
fn term_size() -> Option<(u32, u32)> {
    use std::mem::MaybeUninit;
    let mut ws: MaybeUninit<libc::winsize> = MaybeUninit::uninit();
    let rc = unsafe { libc::ioctl(libc::STDIN_FILENO, libc::TIOCGWINSZ, ws.as_mut_ptr()) };
    if rc == 0 {
        let ws = unsafe { ws.assume_init() };
        if ws.ws_col > 0 && ws.ws_row > 0 {
            return Some((ws.ws_col as u32, ws.ws_row as u32));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use peer_proto::v1::Pong;

    #[test]
    fn framing_roundtrip_via_pipe() {
        use std::io::Cursor;
        let env = Envelope {
            seq: 7,
            correlation_id: 0,
            payload: Some(Payload::Pong(Pong { nonce: 123 })),
        };
        let mut buf = Vec::new();
        write_envelope(&mut buf, &env).unwrap();
        let mut cur = Cursor::new(buf);
        let back = read_envelope(&mut cur).unwrap();
        assert_eq!(back.seq, 7);
        match back.payload.unwrap() {
            Payload::Pong(p) => assert_eq!(p.nonce, 123),
            _ => panic!(),
        }
    }

    #[test]
    fn oversized_frame_is_rejected() {
        use std::io::Cursor;
        let mut buf = Vec::new();
        buf.extend_from_slice(&(MAX_FRAME_BYTES + 1).to_le_bytes());
        let mut cur = Cursor::new(buf);
        let err = read_envelope(&mut cur).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn raw_mode_guard_noop_when_stdin_not_tty() {
        // In cargo test, stdin is a pipe, not a TTY. Enable must be a no-op
        // and Drop must not panic.
        let guard = RawModeGuard::enable();
        assert!(!guard.applied);
        drop(guard);
    }
}
