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
const MAX_RESPONSE_PENDING: usize = 256;

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

// ── Terminal-response filter ───────────────────────────────────────
//
// Ghostty writes terminal query replies (for example OSC 11 color
// reports and CSI cursor-position reports) to the child process stdin.
// In a normal local terminal that child is the program that asked the
// query. In peer relay mode, this binary is the child; forwarding those
// replies as "user input" makes them arrive late at the remote shell,
// where zsh tries to execute fragments such as `11;rgb:...` and `2;1R`.
//
// The host daemon already strips and answers known queries before they
// reach local Ghostty. This is a second, narrow safety net for older
// hosts, replayed output, and any missed query path. It drops only known
// terminal-generated responses; ordinary key input and navigation CSI
// sequences still pass through unchanged.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResponseFilterState {
    Ground,
    Escape,
    Csi,
    Osc,
    OscEsc,
}

#[derive(Debug)]
struct TerminalResponseFilter {
    state: ResponseFilterState,
    pending: Vec<u8>,
}

impl Default for TerminalResponseFilter {
    fn default() -> Self {
        Self {
            state: ResponseFilterState::Ground,
            pending: Vec::with_capacity(64),
        }
    }
}

impl TerminalResponseFilter {
    fn process(&mut self, input: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(input.len());

        for &b in input {
            match self.state {
                ResponseFilterState::Ground => {
                    if b == 0x1B {
                        self.pending.clear();
                        self.pending.push(b);
                        self.state = ResponseFilterState::Escape;
                    } else {
                        out.push(b);
                    }
                }
                ResponseFilterState::Escape => {
                    self.pending.push(b);
                    match b {
                        b'[' => self.state = ResponseFilterState::Csi,
                        b']' => self.state = ResponseFilterState::Osc,
                        _ => {
                            out.extend_from_slice(&self.pending);
                            self.pending.clear();
                            self.state = ResponseFilterState::Ground;
                        }
                    }
                }
                ResponseFilterState::Csi => {
                    self.pending.push(b);
                    if (0x40..=0x7E).contains(&b) {
                        if let Some(replacement) = translate_terminal_csi_input(&self.pending) {
                            out.extend_from_slice(&replacement);
                        } else if !is_terminal_csi_response(&self.pending) {
                            out.extend_from_slice(&self.pending);
                        }
                        self.pending.clear();
                        self.state = ResponseFilterState::Ground;
                    } else if !(0x20..=0x3F).contains(&b) || self.pending.len() > MAX_RESPONSE_PENDING {
                        out.extend_from_slice(&self.pending);
                        self.pending.clear();
                        self.state = ResponseFilterState::Ground;
                    }
                }
                ResponseFilterState::Osc => {
                    if b == 0x07 {
                        if !is_terminal_osc_response(&self.pending) {
                            out.extend_from_slice(&self.pending);
                            out.push(0x07);
                        }
                        self.pending.clear();
                        self.state = ResponseFilterState::Ground;
                    } else if b == 0x1B {
                        self.state = ResponseFilterState::OscEsc;
                    } else {
                        self.pending.push(b);
                        if self.pending.len() > MAX_RESPONSE_PENDING {
                            out.extend_from_slice(&self.pending);
                            self.pending.clear();
                            self.state = ResponseFilterState::Ground;
                        }
                    }
                }
                ResponseFilterState::OscEsc => {
                    if b == b'\\' {
                        if !is_terminal_osc_response(&self.pending) {
                            out.extend_from_slice(&self.pending);
                            out.extend_from_slice(b"\x1B\\");
                        }
                        self.pending.clear();
                        self.state = ResponseFilterState::Ground;
                    } else {
                        out.extend_from_slice(&self.pending);
                        out.push(0x1B);
                        out.push(b);
                        self.pending.clear();
                        self.state = ResponseFilterState::Ground;
                    }
                }
            }
        }

        out
    }

    /// True when the filter is holding a lone ESC waiting for a
    /// follow-up byte. Read loops use this to schedule a short poll
    /// timeout so a user-typed Escape that has no follow-up is
    /// flushed promptly without forwarding it eagerly when the very
    /// next read might complete an OSC/CSI sequence.
    fn has_pending_escape(&self) -> bool {
        self.state == ResponseFilterState::Escape && self.pending == b"\x1B"
    }

    /// Drain a lone pending ESC as user input. The caller is expected
    /// to invoke this when a poll timeout indicates no follow-up byte
    /// is arriving. No-op when the filter is in any other state.
    fn flush_pending_escape(&mut self) -> Vec<u8> {
        if self.has_pending_escape() {
            self.pending.clear();
            self.state = ResponseFilterState::Ground;
            return vec![0x1B];
        }
        Vec::new()
    }
}

fn is_terminal_csi_response(seq: &[u8]) -> bool {
    if seq.len() < 3 || seq[0] != 0x1B || seq[1] != b'[' {
        return false;
    }
    let body = &seq[2..seq.len() - 1];
    let final_byte = seq[seq.len() - 1];

    match final_byte {
        // FocusIn / FocusOut. These are generated by the local relay
        // terminal when a remote full-screen app enables focus tracking.
        // Forwarding them through the peer input path makes "[I"/"[O"
        // appear as literal text in shells and CLIs that do not expect
        // them on the host-side terminal.
        b'I' | b'O' => body.is_empty(),
        // Cursor Position Report: ESC [ row ; col R
        b'R' => !body.is_empty() && body.iter().all(|b| b.is_ascii_digit() || *b == b';'),
        // Device Status Report: ESC [ 0 n, ESC [ 3 n, etc.
        b'n' => !body.is_empty() && body.iter().all(|b| b.is_ascii_digit() || *b == b';' || *b == b'?'),
        // Primary/secondary Device Attributes replies.
        b'c' => {
            if body.starts_with(b"?") || body.starts_with(b">") {
                body[1..].iter().all(|b| b.is_ascii_digit() || *b == b';')
            } else {
                false
            }
        }
        // Kitty keyboard protocol state report: ESC [ ? flags u.
        // Codex enables the protocol in modern terminals; if the local
        // relay terminal answers a mirrored query, forwarding the reply
        // back to the host injects visible "[?7u" into Codex's input.
        b'u' => {
            body.starts_with(b"?")
                && !body[1..].is_empty()
                && body[1..].iter().all(|b| b.is_ascii_digit() || *b == b';')
        }
        _ => false,
    }
}

fn translate_terminal_csi_input(seq: &[u8]) -> Option<Vec<u8>> {
    if seq.len() < 4 || seq[0] != 0x1B || seq[1] != b'[' {
        return None;
    }
    let final_byte = *seq.last()?;
    if final_byte != b'u' {
        return translate_kitty_special_csi_input(seq);
    }

    let body = &seq[2..seq.len() - 1];
    let mut parts = body.split(|b| *b == b';');
    let codepoint = parse_ascii_u32(first_colon_part(parts.next()?))?;
    let (modifiers, event_type) = parse_csi_u_modifiers_and_event(parts.next())?;
    if matches!(event_type, Some(3)) {
        // The local relay terminal can enter kitty report-events mode
        // after mirrored host output. Key release events are not text and
        // become visible "[27;1:3u" / "[97;1:3u" tails in non-kitty hosts.
        return Some(Vec::new());
    }
    if event_type.is_some_and(|event| event != 1 && event != 2) {
        return None;
    }
    if modifiers == 1 {
        if let Some(byte) = csi_u_control_key_byte(codepoint) {
            return Some(vec![byte]);
        }
    }
    // Shift+Enter is the universal "insert literal newline" keybinding for
    // multi-line input fields (codex, claude code, jupyter, …). When the
    // local terminal is in kitty mode it emits `CSI 13 ; 2 u`; the host
    // shell / TUI rarely shares that mode and prints the escape verbatim.
    // Forward an LF instead so the receiving text field sees a newline.
    if modifiers == 2 && codepoint == 13 {
        return Some(vec![b'\n']);
    }
    // Kitty keyboard protocol uses 1-based modifier flags. Ctrl is bit 2
    // after subtracting 1, so Ctrl-only is ";5".
    if modifiers == 0 || ((modifiers - 1) & 0b100) == 0 {
        return None;
    }
    let letter = ctrl_letter_from_codepoint(codepoint)?;
    Some(vec![ctrl_byte_for_ascii_letter(letter)])
}

fn translate_kitty_special_csi_input(seq: &[u8]) -> Option<Vec<u8>> {
    let final_byte = *seq.last()?;
    let body = &seq[2..seq.len() - 1];
    let mut parts = body.split(|b| *b == b';');
    let key = parse_ascii_u32(first_colon_part(parts.next()?))?;
    let (_, event_type) = parse_csi_u_modifiers_and_event(parts.next())?;
    if !is_kitty_special_key(final_byte, key) {
        return None;
    }
    if matches!(event_type, Some(3)) {
        // Special keys such as arrows use final A/B/C/D instead of final u.
        // Release events are not text; forwarding them makes Codex selection
        // UIs move once for press and again for release.
        return Some(Vec::new());
    }
    None
}

fn is_kitty_special_key(final_byte: u8, key: u32) -> bool {
    match final_byte {
        b'A' | b'B' | b'C' | b'D' | b'F' | b'H' | b'P' | b'Q' | b'S' => key == 1,
        b'~' => matches!(key, 2 | 3 | 5 | 6 | 13 | 15 | 17 | 18 | 19 | 20 | 21 | 23 | 24),
        _ => false,
    }
}

fn first_colon_part(bytes: &[u8]) -> &[u8] {
    match bytes.iter().position(|b| *b == b':') {
        Some(idx) => &bytes[..idx],
        None => bytes,
    }
}

fn parse_csi_u_modifiers_and_event(bytes: Option<&[u8]>) -> Option<(u32, Option<u32>)> {
    let Some(bytes) = bytes else {
        return Some((1, None));
    };
    let (modifier_bytes, event_type) = match bytes.iter().position(|b| *b == b':') {
        Some(idx) => (&bytes[..idx], Some(parse_ascii_u32(&bytes[idx + 1..])?)),
        None => (bytes, None),
    };
    Some((parse_ascii_u32(modifier_bytes)?, event_type))
}

fn csi_u_control_key_byte(codepoint: u32) -> Option<u8> {
    match codepoint {
        9 => Some(b'\t'),  // Tab
        13 => Some(b'\r'), // Enter
        27 => Some(0x1B),  // Escape
        127 => Some(0x7F), // Backspace / Delete
        _ => None,
    }
}

fn parse_ascii_u32(bytes: &[u8]) -> Option<u32> {
    if bytes.is_empty() || !bytes.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut value = 0u32;
    for &b in bytes {
        value = value.checked_mul(10)?.checked_add(u32::from(b - b'0'))?;
    }
    Some(value)
}

fn ctrl_byte_for_ascii_letter(letter: u8) -> u8 {
    letter.to_ascii_lowercase() - b'a' + 1
}

fn ctrl_letter_from_codepoint(codepoint: u32) -> Option<u8> {
    const ASCII_LOWER_A: u32 = b'a' as u32;
    const ASCII_LOWER_Z: u32 = b'z' as u32;
    const ASCII_UPPER_A: u32 = b'A' as u32;
    const ASCII_UPPER_Z: u32 = b'Z' as u32;

    match codepoint {
        ASCII_LOWER_A..=ASCII_LOWER_Z => Some(codepoint as u8),
        ASCII_UPPER_A..=ASCII_UPPER_Z => Some((codepoint as u8).to_ascii_lowercase()),
        // Korean 2-set IME can make Ghostty encode the physical Ctrl+key
        // as the Hangul jamo produced by that key. Map those jamo back to
        // their QWERTY physical letters so Ctrl+C still becomes ETX.
        0x3142 | 0x3143 => Some(b'q'), // ㅂ / ㅃ
        0x3148 | 0x3149 => Some(b'w'), // ㅈ / ㅉ
        0x3137 | 0x3138 => Some(b'e'), // ㄷ / ㄸ
        0x3131 | 0x3132 => Some(b'r'), // ㄱ / ㄲ
        0x3145 | 0x3146 => Some(b't'), // ㅅ / ㅆ
        0x315B => Some(b'y'),          // ㅛ
        0x3155 => Some(b'u'),          // ㅕ
        0x3151 => Some(b'i'),          // ㅑ
        0x3150 | 0x3152 => Some(b'o'), // ㅐ / ㅒ
        0x3154 | 0x3156 => Some(b'p'), // ㅔ / ㅖ
        0x3141 => Some(b'a'),          // ㅁ
        0x3134 => Some(b's'),          // ㄴ
        0x3147 => Some(b'd'),          // ㅇ
        0x3139 => Some(b'f'),          // ㄹ
        0x314E => Some(b'g'),          // ㅎ
        0x3157 => Some(b'h'),          // ㅗ
        0x3153 => Some(b'j'),          // ㅓ
        0x314F => Some(b'k'),          // ㅏ
        0x3163 => Some(b'l'),          // ㅣ
        0x314B => Some(b'z'),          // ㅋ
        0x314C => Some(b'x'),          // ㅌ
        0x314A => Some(b'c'),          // ㅊ
        0x314D => Some(b'v'),          // ㅍ
        0x3160 => Some(b'b'),          // ㅠ
        0x315C => Some(b'n'),          // ㅜ
        0x3161 => Some(b'm'),          // ㅡ
        _ => None,
    }
}

fn is_terminal_osc_response(seq_without_terminator: &[u8]) -> bool {
    if seq_without_terminator.len() < 4
        || seq_without_terminator[0] != 0x1B
        || seq_without_terminator[1] != b']'
    {
        return false;
    }
    let payload = &seq_without_terminator[2..];
    let Some(semi) = payload.iter().position(|&b| b == b';') else {
        return false;
    };
    let ps = &payload[..semi];
    let value = &payload[semi + 1..];

    match ps {
        // Color reports for fg / bg / cursor / mouse / etc. (OSC 10..19).
        // Ghostty replies `OSC Ps ; rgb:RRRR/GGGG/BBBB` to `OSC Ps ; ?`
        // queries. Restrict the drop to payloads that actually look like
        // a colour value so a user legitimately typing
        // `printf '\e]11;custom\e\\'` is not silently swallowed.
        b"10" | b"11" | b"12" | b"13" | b"14" | b"15" | b"16" | b"17" | b"18" | b"19" => {
            value.starts_with(b"rgb:") || value.starts_with(b"rgba:")
        }
        // Palette colour query reply: `OSC 4 ; n ; rgb:...`. The
        // colour value lives after the *second* semicolon, not the
        // first, so we have to look one level deeper than the
        // 10..19 case.
        b"4" => {
            if let Some(second_semi) = value.iter().position(|&b| b == b';') {
                let v = &value[second_semi + 1..];
                v.starts_with(b"rgb:") || v.starts_with(b"rgba:")
            } else {
                false
            }
        }
        // Clipboard read reply. Ghostty answers a host-issued
        // `OSC 52 ; <Pc> ; ?` query with `OSC 52 ; <Pc> ; <BASE64>`,
        // and the bytes flow back here on the relay's stdin. Without
        // this drop the relay would forward the BASE64 payload as
        // ordinary user input — a clipboard exfiltration channel for
        // any peer host that asks. The reply and the user-typed set
        // form (`OSC 52 ; c ; data`) are byte-identical, so we drop
        // every OSC 52 the relay sees rather than risk leaking. Users
        // who need clipboard manipulation in the remote pane should
        // route it through an explicit channel, not raw OSC.
        b"52" => true,
        // Kitty's clipboard / file extension. Same shape, same risk.
        b"5522" => true,
        _ => false,
    }
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

    // stdin reader thread: sends keystrokes to socket. Uses poll(2)
    // so a lone ESC held by `TerminalResponseFilter` (waiting to see
    // if it's the start of a CSI/OSC sequence) can be flushed after
    // a short timeout — the standard "Escape timing" trick TUIs use
    // to disambiguate Esc-by-itself from `Esc[A` arrow keys without
    // racing read boundaries. Without poll, we'd either flush every
    // ESC eagerly (the original code, which lets a CSI/OSC reply
    // split as `[ESC][[2;1R]` slip through as raw input) or hold ESC
    // forever (which makes vim's `<Esc>` to leave insert mode hang).
    let tx_stdin = tx.clone();
    let stdin_handle = std::thread::spawn(move || {
        // Bounded delay between seeing a lone ESC and forwarding it
        // as user input. 100 ms is well above any same-burst
        // PTY read-fragmentation jitter and well below human Escape
        // perception latency.
        const ESC_FLUSH_TIMEOUT_MS: i32 = 100;

        let stdin_fd = libc::STDIN_FILENO;
        let mut buf = [0u8; 1024];
        let mut response_filter = TerminalResponseFilter::default();

        let send_frame = |tx: &mpsc::Sender<Vec<u8>>, payload: &[u8]| -> bool {
            if payload.is_empty() {
                return true;
            }
            let mut frame = Vec::with_capacity(5 + payload.len());
            frame.push(TYPE_KEY_INPUT);
            frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
            frame.extend_from_slice(payload);
            tx.send(frame).is_ok()
        };

        loop {
            let timeout_ms = if response_filter.has_pending_escape() {
                ESC_FLUSH_TIMEOUT_MS
            } else {
                -1
            };
            let mut pfd = libc::pollfd {
                fd: stdin_fd,
                events: libc::POLLIN,
                revents: 0,
            };
            let ret = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
            if ret < 0 {
                let err = io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                break;
            }
            if ret == 0 {
                let flushed = response_filter.flush_pending_escape();
                if !send_frame(&tx_stdin, &flushed) {
                    break;
                }
                continue;
            }
            if pfd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                break;
            }
            if pfd.revents & libc::POLLIN == 0 {
                continue;
            }
            let n = unsafe {
                libc::read(stdin_fd, buf.as_mut_ptr() as *mut _, buf.len())
            };
            if n == 0 {
                break;
            }
            if n < 0 {
                let err = io::Error::last_os_error();
                match err.raw_os_error() {
                    Some(libc::EINTR) | Some(libc::EAGAIN) => continue,
                    _ => break,
                }
            }
            let filtered = response_filter.process(&buf[..n as usize]);
            if !send_frame(&tx_stdin, &filtered) {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn filter(input: &[u8]) -> Vec<u8> {
        let mut f = TerminalResponseFilter::default();
        f.process(input)
    }

    #[test]
    fn passes_plain_user_input() {
        assert_eq!(filter(b"gk pull\r"), b"gk pull\r");
    }

    #[test]
    fn passes_arrow_key_input() {
        assert_eq!(filter(b"\x1B[A"), b"\x1B[A");
    }

    #[test]
    fn passes_kitty_arrow_press_and_repeat_events() {
        assert_eq!(filter(b"\x1B[1;1:1B"), b"\x1B[1;1:1B");
        assert_eq!(filter(b"\x1B[1;1:2A"), b"\x1B[1;1:2A");
    }

    #[test]
    fn drops_kitty_arrow_release_events() {
        assert!(filter(b"\x1B[1;1:3A").is_empty());
        assert!(filter(b"\x1B[1;1:3B").is_empty());
        assert!(filter(b"\x1B[1;2:3A").is_empty());
        assert!(filter(b"\x1B[1;5:3P").is_empty());
    }

    #[test]
    fn drops_kitty_tilde_special_release_events() {
        assert!(filter(b"\x1B[5;1:3~").is_empty());
        assert!(filter(b"\x1B[13;2:3~").is_empty());
    }

    #[test]
    fn translates_ascii_csi_u_ctrl_c_to_etx() {
        assert_eq!(filter(b"\x1B[99;5u"), b"\x03");
    }

    #[test]
    fn translates_csi_u_escape_to_escape() {
        assert_eq!(filter(b"\x1B[27u"), b"\x1B");
        assert_eq!(filter(b"\x1B[27;1u"), b"\x1B");
        assert_eq!(filter(b"\x1B[27;1:1u"), b"\x1B");
        assert_eq!(filter(b"\x1B[27;1:2u"), b"\x1B");
    }

    #[test]
    fn translates_shift_enter_to_newline() {
        assert_eq!(filter(b"\x1B[13;2u"), b"\n");
        assert_eq!(filter(b"\x1B[13;2:1u"), b"\n");
        assert_eq!(filter(b"\x1B[13;2:2u"), b"\n");
    }

    #[test]
    fn drops_shift_enter_release_event() {
        assert!(filter(b"\x1B[13;2:3u").is_empty());
    }

    #[test]
    fn drops_csi_u_escape_release_event() {
        assert!(filter(b"\x1B[27;1:3u").is_empty());
    }

    #[test]
    fn drops_csi_u_printable_release_event() {
        assert!(filter(b"\x1B[97;1:3u").is_empty());
        assert!(filter(b"\x1B[106:74;2:3u").is_empty());
        assert!(filter(b"\x1B[127;1:3;65u").is_empty());
        assert!(filter(b"\x1B[337::91;5:3u").is_empty());
    }

    #[test]
    fn drops_csi_u_modifier_release_event() {
        assert!(filter(b"\x1B[57442;5:3u").is_empty());
    }

    #[test]
    fn translates_csi_u_basic_control_keys() {
        assert_eq!(filter(b"\x1B[9u"), b"\t");
        assert_eq!(filter(b"\x1B[13u"), b"\r");
        assert_eq!(filter(b"\x1B[127u"), b"\x7f");
    }

    #[test]
    fn translates_korean_ime_csi_u_ctrl_c_to_etx() {
        // 0x314A / 12618 is "ㅊ", the Korean 2-set jamo on the
        // physical C key. Ghostty may emit it when Ctrl+C is pressed
        // while the Korean IME layout is active.
        assert_eq!(filter(b"\x1B[12618;5u"), b"\x03");
    }

    #[test]
    fn translates_reported_korean_ime_csi_u_ctrl_a() {
        // 0x3141 / 12609 is "ㅁ", the Korean 2-set jamo on physical A.
        assert_eq!(filter(b"\x1B[12609;5u"), b"\x01");
    }

    #[test]
    fn holds_lone_escape_pending_for_followup() {
        let mut f = TerminalResponseFilter::default();
        // A lone ESC must NOT be flushed inside `process` — that would
        // turn a CSI/OSC reply split across read boundaries (ESC, then
        // `[2;1R` on the next read) into ordinary input. The read loop
        // arms a poll timeout to flush these via `flush_pending_escape`.
        assert!(f.process(b"\x1B").is_empty());
        assert!(f.has_pending_escape());
        assert_eq!(f.flush_pending_escape(), b"\x1B");
        assert!(!f.has_pending_escape());
    }

    #[test]
    fn flush_pending_escape_is_noop_when_idle() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.flush_pending_escape().is_empty());
        // Mid-CSI must not be flushed by the timeout helper either.
        let _ = f.process(b"\x1B[");
        assert!(f.flush_pending_escape().is_empty());
    }

    #[test]
    fn drops_osc_11_rgb_response_with_st() {
        assert!(filter(b"\x1B]11;rgb:f8f8/efef/e7e7\x1B\\").is_empty());
    }

    #[test]
    fn drops_osc_10_rgb_response_with_bel() {
        assert!(filter(b"\x1B]10;rgb:ffff/ffff/ffff\x07").is_empty());
    }

    #[test]
    fn keeps_non_color_osc_input() {
        assert_eq!(filter(b"\x1B]0;title\x07"), b"\x1B]0;title\x07");
    }

    #[test]
    fn drops_cursor_position_report() {
        assert!(filter(b"\x1B[2;1R").is_empty());
    }

    #[test]
    fn drops_status_and_device_attribute_responses() {
        assert!(filter(b"\x1B[0n").is_empty());
        assert!(filter(b"\x1B[?1;2c").is_empty());
        assert!(filter(b"\x1B[>1;95;0c").is_empty());
    }

    #[test]
    fn drops_focus_in_out_events() {
        assert!(filter(b"\x1B[I").is_empty());
        assert!(filter(b"\x1B[O").is_empty());
    }

    #[test]
    fn drops_kitty_keyboard_state_response() {
        assert!(filter(b"\x1B[?7u").is_empty());
        assert!(filter(b"\x1B[?31u").is_empty());
    }

    #[test]
    fn drops_mixed_response_burst_without_touching_user_text() {
        let mut f = TerminalResponseFilter::default();
        let out = f.process(b"ok\x1B]11;rgb:f8f8/efef/e7e7\x1B\\\x1B[2;1R\r");
        assert_eq!(out, b"ok\r");
    }

    #[test]
    fn handles_split_osc_response() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.process(b"\x1B]11;rgb:f8").is_empty());
        assert!(f.process(b"f8/efef/e7e7\x1B\\").is_empty());
    }

    #[test]
    fn handles_split_cpr_response() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.process(b"\x1B[2;").is_empty());
        assert!(f.process(b"1R").is_empty());
    }

    /// Regression for the Codex finding: an OSC/CSI reply split as
    /// `ESC` then `[2;1R` (or `]11;...`) used to slip through because
    /// `process` flushed the lone ESC at the end of each read,
    /// resetting state to Ground. The fix holds ESC pending across
    /// reads so the second chunk completes the sequence and is
    /// dropped intact.
    #[test]
    fn drops_csi_response_split_after_escape() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.process(b"\x1B").is_empty());
        assert!(f.process(b"[2;1R").is_empty());
    }

    #[test]
    fn drops_kitty_keyboard_state_response_split_after_escape() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.process(b"\x1B").is_empty());
        assert!(f.process(b"[?7u").is_empty());
    }

    #[test]
    fn drops_csi_u_escape_release_split_after_escape() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.process(b"\x1B").is_empty());
        assert!(f.process(b"[27;1:3u").is_empty());
    }

    #[test]
    fn drops_kitty_arrow_release_split_after_escape() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.process(b"\x1B").is_empty());
        assert!(f.process(b"[1;1:3B").is_empty());
    }

    #[test]
    fn drops_osc_response_split_after_escape() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.process(b"\x1B").is_empty());
        assert!(f
            .process(b"]11;rgb:f8f8/efef/e7e7\x1B\\")
            .is_empty());
    }

    /// Regression for the Codex high finding: OSC 52 clipboard read
    /// replies (`\x1b]52;c;BASE64\x07`) used to be forwarded as user
    /// input because the filter only matched OSC 10..19 colours.
    /// Forwarding leaks the local clipboard to the remote host.
    #[test]
    fn drops_osc_52_clipboard_read_reply_with_bel() {
        assert!(filter(b"\x1B]52;c;SGVsbG8gd29ybGQ=\x07").is_empty());
    }

    #[test]
    fn drops_osc_52_clipboard_read_reply_with_st() {
        assert!(filter(b"\x1B]52;c;SGVsbG8gd29ybGQ=\x1B\\").is_empty());
    }

    #[test]
    fn drops_osc_52_split_after_escape() {
        let mut f = TerminalResponseFilter::default();
        assert!(f.process(b"\x1B").is_empty());
        assert!(f.process(b"]52;c;SGVsbG8=\x07").is_empty());
    }

    #[test]
    fn drops_osc_4_palette_response() {
        assert!(filter(b"\x1B]4;5;rgb:8080/8080/8080\x07").is_empty());
    }

    #[test]
    fn drops_osc_5522_kitty_extension_response() {
        assert!(filter(b"\x1B]5522;c;ZGF0YQ==\x07").is_empty());
    }

    #[test]
    fn keeps_osc_0_title_set() {
        // Title set is not a Ghostty-generated reply — user / shell
        // may legitimately send it. Must continue to pass through.
        assert_eq!(filter(b"\x1B]0;hello\x07"), b"\x1B]0;hello\x07");
    }
}
