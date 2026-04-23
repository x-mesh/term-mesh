//! Peer-federation client for tm-agent (Phase 2.2b).
//!
//! Headless verification tool: connects to a host term-mesh peer socket,
//! walks the handshake, attaches to the first available surface, streams
//! PtyData to stdout, and relays stdin (line-buffered) as Input.
//!
//! Scope note: intentionally sync (std::os::unix::net::UnixStream + threads)
//! to avoid dragging tokio into term-mesh-cli. Terminal raw-mode, SIGWINCH
//! tracking, and rich keybindings land in Phase 2.3+.

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use peer_proto::v1::{
    AttachMode, AttachSurface, Auth, Envelope, Goodbye, Hello, Input, ListSurfaces,
};
use peer_proto::v1::envelope::Payload;
use peer_proto::MAX_FRAME_BYTES;
use prost::Message;

const PROTOCOL_VERSION: &str = "1.0.0";
const DEFAULT_COLS: u32 = 80;
const DEFAULT_ROWS: u32 = 24;

pub fn attach_cmd(socket_path: &Path) -> anyhow::Result<()> {
    let stream = UnixStream::connect(socket_path)
        .map_err(|e| anyhow::anyhow!("connect {}: {e}", socket_path.display()))?;
    let mut read_stream = stream.try_clone()?;
    let mut write_stream = stream;

    let seq = Arc::new(AtomicU64::new(0));

    // ---- handshake ----
    let peer_id = random_16_bytes();
    let client_hello = Envelope {
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
    };
    write_envelope(&mut write_stream, &client_hello)?;

    let host_hello = read_envelope(&mut read_stream)?;
    let Some(Payload::Hello(h)) = host_hello.payload else {
        anyhow::bail!("host did not send Hello first");
    };
    eprintln!(
        "[peer] connected to {} ({}), protocol {}",
        h.display_name, h.app_version, h.protocol_version
    );

    let challenge = read_envelope(&mut read_stream)?;
    match challenge.payload {
        Some(Payload::AuthChallenge(_)) => {}
        other => anyhow::bail!("expected AuthChallenge, got {other:?}"),
    }

    let auth = Envelope {
        seq: next_seq(&seq),
        correlation_id: 0,
        payload: Some(Payload::Auth(Auth {
            method: "ssh-passthrough".into(),
            token_id: vec![],
            signature: vec![],
        })),
    };
    write_envelope(&mut write_stream, &auth)?;

    let auth_result = read_envelope(&mut read_stream)?;
    match auth_result.payload {
        Some(Payload::AuthResult(r)) if r.accepted => {
            eprintln!("[peer] authenticated");
        }
        Some(Payload::AuthResult(r)) => anyhow::bail!("auth rejected: {}", r.reason),
        other => anyhow::bail!("expected AuthResult, got {other:?}"),
    }

    // ---- list + pick first surface ----
    let list = Envelope {
        seq: next_seq(&seq),
        correlation_id: 0,
        payload: Some(Payload::ListSurfaces(ListSurfaces {})),
    };
    write_envelope(&mut write_stream, &list)?;
    let list_reply = read_envelope(&mut read_stream)?;
    let surfaces = match list_reply.payload {
        Some(Payload::SurfaceList(sl)) => sl.surfaces,
        other => anyhow::bail!("expected SurfaceList, got {other:?}"),
    };
    let chosen = surfaces
        .first()
        .ok_or_else(|| anyhow::anyhow!("host reports no attachable surfaces"))?
        .clone();
    eprintln!(
        "[peer] attaching surface {:?} ({}) {}x{}",
        hex_short(&chosen.surface_id),
        chosen.title,
        chosen.cols,
        chosen.rows
    );
    let surface_id = chosen.surface_id.clone();

    // ---- attach ----
    let (cols, rows) = term_size().unwrap_or((DEFAULT_COLS, DEFAULT_ROWS));
    let attach = Envelope {
        seq: next_seq(&seq),
        correlation_id: 0,
        payload: Some(Payload::AttachSurface(AttachSurface {
            surface_id: surface_id.clone(),
            mode: AttachMode::CoWrite as i32,
            client_cols: cols,
            client_rows: rows,
            resume_from_seq: 0,
        })),
    };
    write_envelope(&mut write_stream, &attach)?;
    let attach_reply = read_envelope(&mut read_stream)?;
    match attach_reply.payload {
        Some(Payload::AttachResult(r)) if r.accepted => {
            eprintln!("[peer] attached; streaming. Ctrl+D to detach.");
        }
        Some(Payload::AttachResult(r)) => anyhow::bail!("attach rejected: {}", r.reason),
        other => anyhow::bail!("expected AttachResult, got {other:?}"),
    }

    // ---- reader thread ----
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
                Some(Payload::Error(e)) => {
                    eprintln!("[peer error {}] {}", e.code, e.message);
                    if e.code >= 500 {
                        return Ok(());
                    }
                }
                Some(Payload::Goodbye(g)) => {
                    eprintln!("[peer] host goodbye: {}", g.reason);
                    return Ok(());
                }
                Some(Payload::Pong(_)) => {}
                _ => {}
            }
        }
    });

    // ---- stdin relay ----
    let stdin = io::stdin();
    let mut buf = [0u8; 1024];
    loop {
        let n = match stdin.lock().read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.into()),
        };
        let input = Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Input(Input {
                surface_id: surface_id.clone(),
                kind: Some(peer_proto::v1::input::Kind::Keys(buf[..n].to_vec())),
            })),
        };
        if write_envelope(&mut write_stream, &input).is_err() {
            break;
        }
    }

    // ---- graceful goodbye ----
    let _ = write_envelope(
        &mut write_stream,
        &Envelope {
            seq: next_seq(&seq),
            correlation_id: 0,
            payload: Some(Payload::Goodbye(Goodbye {
                reason: "client detach".into(),
            })),
        },
    );
    let _ = write_stream.shutdown(std::net::Shutdown::Write);
    let _ = reader_handle.join();
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

// ── helpers ───────────────────────────────────────────────────────

fn next_seq(seq: &AtomicU64) -> u64 {
    seq.fetch_add(1, Ordering::Relaxed) + 1
}

fn random_16_bytes() -> Vec<u8> {
    // Not cryptographic — just a unique client identifier for the session.
    // peer_id is used by hosts to key per-device authorization; PoC doesn't care.
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
    bytes[..n]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>()
}

#[cfg(unix)]
fn term_size() -> Option<(u32, u32)> {
    use std::mem::MaybeUninit;
    let mut ws: MaybeUninit<libc::winsize> = MaybeUninit::uninit();
    // Safety: ioctl(TIOCGWINSZ) reads the size of stdin's controlling terminal.
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
}
