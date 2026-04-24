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
use std::sync::mpsc;

const TYPE_PTY_DATA: u8 = 0x01;
const TYPE_KEY_INPUT: u8 = 0x02;
const TYPE_RESIZE: u8 = 0x03;
const TYPE_GOODBYE: u8 = 0xFF;

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

// ── Framing ────────────────────────────────────────────────────────

fn write_frame(sock: &mut UnixStream, typ: u8, payload: &[u8]) -> io::Result<()> {
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
        while let Ok(frame) = rx.recv() {
            if sock_write.write_all(&frame).is_err() {
                break;
            }
            let _ = sock_write.flush();
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
    let log_path = "/tmp/peer-relay-binary.log";
    let mut rlog = std::fs::OpenOptions::new()
        .create(true).append(true).open(log_path).ok();
    macro_rules! rlog {
        ($($arg:tt)*) => {
            if let Some(ref mut f) = rlog {
                let _ = writeln!(f, "[relay-bin] {}", format!($($arg)*));
            }
        };
    }
    rlog!("main loop starting");
    let stdout = io::stdout();
    loop {
        match read_frame(&mut sock) {
            Err(e) => { rlog!("read_frame error: {e}"); break; }
            Ok((TYPE_PTY_DATA, payload)) => {
                let mut out = stdout.lock();
                if let Err(e) = out.write_all(&payload) {
                    rlog!("stdout write_all error: {e} (payload {}B)", payload.len());
                    break;
                }
                if let Err(e) = out.flush() {
                    rlog!("stdout flush error: {e}");
                    break;
                }
            }
            Ok((TYPE_GOODBYE, reason)) => {
                rlog!("got GOODBYE: {}", String::from_utf8_lossy(&reason));
                break;
            }
            Ok((t, _)) => { rlog!("unknown frame type 0x{t:02x}"); }
        }
    }
    rlog!("main loop exited");

    STOPPING.store(true, Ordering::Relaxed);

    // Close SIGWINCH pipe write end so the sigwinch thread unblocks.
    let wfd = SIGWINCH_PIPE_WRITE.swap(-1, Ordering::Relaxed);
    if wfd >= 0 {
        unsafe { libc::close(wfd); }
    }

    // Signal stdin thread to stop (it may be blocked in read; closing
    // stdin fd would help but is too destructive — just let it die on EOF).
    drop(tx_stop); // drop our tx clone so writer unblocks when stdin also drops
    drop(tx);

    let _ = stdin_handle.join();
    let _ = writer_handle.join();
    if let Some(h) = sigwinch_handle {
        let _ = h.join();
    }
}
