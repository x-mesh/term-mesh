//! term-mesh-peer-relay — PTY relay shim for peer-federation remote panes.
//!
//! Ghostty spawns this binary as the "shell" for a remote pane.
//! The binary connects to a Unix socket managed by PeerRelaySession (Swift),
//! then bidirectionally relays:
//!   socket type=0x01 (PtyData) → write to stdout → Ghostty renders
//!   stdin (keystrokes from Ghostty) → socket type=0x02 → PeerSession Input
//!   SIGWINCH → ioctl(TIOCGWINSZ) on stdin → socket type=0x03 → PeerSession Resize
//!
//! Socket framing (both directions):
//!   [type: u8][len: u32 LE][payload: len bytes]
//!
//! Types:
//!   0x01  PtyData   host→relay (app sends this to relay)
//!   0x02  KeyInput  relay→host (relay sends keystrokes to app)
//!   0x03  Resize    relay→host (cols: u16 LE, rows: u16 LE)
//!   0xFF  Goodbye   either direction — teardown

use std::env;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::Duration;

const TYPE_PTY_DATA: u8 = 0x01;
const TYPE_KEY_INPUT: u8 = 0x02;
const TYPE_RESIZE: u8 = 0x03;
const TYPE_GOODBYE: u8 = 0xFF;
const TYPE_AUTH: u8 = 0xFE;
const MAX_FRAME_BYTES: usize = 1024 * 1024;

// ── SIGWINCH self-pipe ─────────────────────────────────────────────

static SIGWINCH_PIPE_WRITE: AtomicI32 = AtomicI32::new(-1);
static STOPPING: AtomicBool = AtomicBool::new(false);

extern "C" fn sigwinch_handler(_: libc::c_int) {
    let fd = SIGWINCH_PIPE_WRITE.load(Ordering::Relaxed);
    if fd >= 0 {
        let b = [1u8];
        unsafe {
            libc::write(fd, b.as_ptr() as *const _, 1);
        }
    }
}

fn install_sigwinch_pipe() -> io::Result<libc::c_int> {
    let mut fds = [0i32; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    SIGWINCH_PIPE_WRITE.store(fds[1], Ordering::Relaxed);
    let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
    sa.sa_sigaction = sigwinch_handler as *const () as usize;
    sa.sa_flags = libc::SA_RESTART;
    unsafe {
        libc::sigemptyset(&mut sa.sa_mask);
        libc::sigaction(libc::SIGWINCH, &sa, std::ptr::null_mut());
    }
    Ok(fds[0])
}

fn current_winsize() -> Option<(u16, u16)> {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::ioctl(libc::STDIN_FILENO, libc::TIOCGWINSZ, &mut ws) };
    if rc == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        Some((ws.ws_col, ws.ws_row))
    } else {
        None
    }
}

// ── Raw stdin ──────────────────────────────────────────────────────
//
// Without raw mode, stdin is line-buffered: Tab / Ctrl-C / arrow keys
// stay queued in the kernel line buffer until Enter is pressed, so the
// host never sees them. cfmakeraw + tcsetattr makes every keystroke
// visible to read(2) immediately. The original termios is captured at
// startup and restored on exit.

struct RawStdinGuard {
    original: Option<libc::termios>,
}

impl RawStdinGuard {
    fn enable() -> Self {
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        let got = unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) };
        if got != 0 {
            return Self { original: None };
        }
        let mut raw = original;
        unsafe { libc::cfmakeraw(&mut raw) };
        // VMIN=1, VTIME=0 → read returns as soon as one byte is available.
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        let set = unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) };
        if set != 0 {
            return Self { original: None };
        }
        Self { original: Some(original) }
    }
}

impl Drop for RawStdinGuard {
    fn drop(&mut self) {
        if let Some(ref tio) = self.original {
            unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, tio) };
        }
    }
}

// ── Framing ────────────────────────────────────────────────────────

fn write_frame(sock: &mut UnixStream, typ: u8, payload: &[u8]) -> io::Result<()> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("relay frame length {} exceeds {}", payload.len(), MAX_FRAME_BYTES),
        ));
    }
    let mut header = [0u8; 5];
    header[0] = typ;
    let len = payload.len() as u32;
    header[1..5].copy_from_slice(&len.to_le_bytes());
    sock.write_all(&header)?;
    sock.write_all(payload)?;
    sock.flush()
}

fn read_frame(sock: &mut UnixStream) -> io::Result<(u8, Vec<u8>)> {
    let mut header = [0u8; 5];
    sock.read_exact(&mut header)?;
    let typ = header[0];
    let len = u32::from_le_bytes(header[1..5].try_into().unwrap()) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("relay frame length {len} exceeds {MAX_FRAME_BYTES}"),
        ));
    }
    let mut payload = vec![0u8; len];
    if len > 0 {
        sock.read_exact(&mut payload)?;
    }
    Ok((typ, payload))
}

// ── Main ────────────────────────────────────────────────────────────

fn main() {
    let socket_path = env::var("TERMMESH_PEER_RELAY_SOCKET").unwrap_or_else(|_| {
        eprintln!("[relay] TERMMESH_PEER_RELAY_SOCKET not set");
        std::process::exit(1);
    });

    let mut sock = UnixStream::connect(&socket_path).unwrap_or_else(|e| {
        eprintln!("[relay] connect {socket_path}: {e}");
        std::process::exit(1);
    });
    let relay_secret = env::var("TERMMESH_PEER_RELAY_SECRET").unwrap_or_else(|_| {
        eprintln!("[relay] TERMMESH_PEER_RELAY_SECRET not set");
        std::process::exit(1);
    });
    if let Err(e) = write_frame(&mut sock, TYPE_AUTH, relay_secret.as_bytes()) {
        eprintln!("[relay] auth handshake failed: {e}");
        std::process::exit(1);
    }

    // Put stdin in raw mode so each keystroke (Tab, Ctrl-C, arrow keys)
    // is forwarded immediately instead of waiting for a newline flush.
    // Restored automatically on drop at the end of main().
    let _raw_guard = RawStdinGuard::enable();

    // Send initial Resize so the host knows our terminal size.
    if let Some((cols, rows)) = current_winsize() {
        let mut payload = [0u8; 4];
        payload[..2].copy_from_slice(&cols.to_le_bytes());
        payload[2..4].copy_from_slice(&rows.to_le_bytes());
        let _ = write_frame(&mut sock, TYPE_RESIZE, &payload);
    }

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let tx_stop = tx.clone();

    // SIGWINCH pipe
    let sigwinch_rx_fd = install_sigwinch_pipe().ok();

    // Writer thread: receives frames from channel, writes to socket.
    let mut sock_write = sock.try_clone().unwrap();
    let writer_handle = std::thread::spawn(move || {
        loop {
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(frame) => {
                    if sock_write.write_all(&frame).is_err() {
                        break;
                    }
                    let _ = sock_write.flush();
                }
                Err(RecvTimeoutError::Timeout) if STOPPING.load(Ordering::Relaxed) => break,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => break,
            }
        }
        let _ = write_frame(&mut sock_write, TYPE_GOODBYE, b"relay-eof");
    });

    // SIGWINCH thread
    let sigwinch_handle = sigwinch_rx_fd.map(|fd| {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut scratch = [0u8; 16];
            loop {
                let n = unsafe { libc::read(fd, scratch.as_mut_ptr() as *mut _, scratch.len()) };
                if n <= 0 || STOPPING.load(Ordering::Relaxed) {
                    break;
                }
                if let Some((cols, rows)) = current_winsize() {
                    let mut payload = [0u8; 4];
                    payload[..2].copy_from_slice(&cols.to_le_bytes());
                    payload[2..4].copy_from_slice(&rows.to_le_bytes());
                    let mut frame = Vec::with_capacity(5 + 4);
                    frame.push(TYPE_RESIZE);
                    frame.extend_from_slice(&4u32.to_le_bytes());
                    frame.extend_from_slice(&payload);
                    if tx.send(frame).is_err() {
                        break;
                    }
                }
            }
        })
    });

    // stdin reader thread: sends keystrokes to socket.
    let tx_stdin = tx.clone();
    let stdin_handle = std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut buf = [0u8; 1024];
        loop {
            let n = match stdin.lock().read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            let mut frame = Vec::with_capacity(5 + n);
            frame.push(TYPE_KEY_INPUT);
            frame.extend_from_slice(&(n as u32).to_le_bytes());
            frame.extend_from_slice(&buf[..n]);
            if tx_stdin.send(frame).is_err() {
                break;
            }
        }
    });

    // Socket reader (main thread): receives PtyData and writes to stdout.
    let stdout = io::stdout();
    loop {
        match read_frame(&mut sock) {
            Err(_) => break,
            Ok((TYPE_PTY_DATA, payload)) => {
                let mut out = stdout.lock();
                if out.write_all(&payload).is_err() { break; }
                if out.flush().is_err() { break; }
            }
            Ok((TYPE_GOODBYE, _)) => break,
            Ok((_, _)) => {}
        }
    }

    STOPPING.store(true, Ordering::Relaxed);

    // Close SIGWINCH pipe write end so the sigwinch thread unblocks.
    let wfd = SIGWINCH_PIPE_WRITE.swap(-1, Ordering::Relaxed);
    if wfd >= 0 {
        unsafe { libc::close(wfd); }
    }

    // The stdin reader may be blocked inside the PTY read. Let process exit
    // tear it down instead of joining forever during relay shutdown.
    drop(tx_stop);
    drop(tx);

    drop(stdin_handle);
    let _ = writer_handle.join();
    if let Some(h) = sigwinch_handle {
        let _ = h.join();
    }
}
