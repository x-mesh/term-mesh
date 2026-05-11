// term-meshd-tmux-relay — bridges a Ghostty PTY and tmux over term-meshd RPCs.
//
// Ghostty spawns this binary as the "shell" for a TmuxRelayWindowController.
// The binary connects to term-meshd, attaches to the remote tmux session,
// subscribes to the output stream, decodes hex-encoded frames, and writes
// raw PTY bytes to stdout — which Ghostty renders in the terminal surface.
// It also reads Ghostty's PTY stdin and forwards input to
// multiplexer.tmux.input so the remote tmux pane is interactive.
//
// Env vars:
//   TERMMESH_DAEMON_UNIX_PATH  — path to term-meshd socket (required)
//   TERMMESH_TMUX_HOST         — SSH host (e.g. ubuntu@100.70.102.125)
//   TERMMESH_TMUX_SESSION      — tmux session name

use std::os::unix::io::AsRawFd;
use std::path::PathBuf;

use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::signal::unix::{signal, SignalKind};

/// Query the controlling TTY (stdout) for its current size. macOS Ghostty
/// gives the relay a real PTY, so TIOCGWINSZ works against any of stdin/
/// stdout/stderr. Returns (cols, rows).
fn current_winsize() -> Option<(u16, u16)> {
    #[repr(C)]
    struct WinSize {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    }
    const TIOCGWINSZ: libc::c_ulong = 0x40087468;
    let fd = std::io::stdout().as_raw_fd();
    let mut ws = WinSize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(fd, TIOCGWINSZ, &mut ws as *mut WinSize as *mut libc::c_void) };
    if rc == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        Some((ws.ws_col, ws.ws_row))
    } else {
        None
    }
}

// ── Raw stdin ──────────────────────────────────────────────────────
//
// Ghostty gives the relay a real PTY. If the relay leaves that PTY in
// canonical mode, keys such as Tab, Ctrl-C, arrows, and ordinary text are
// buffered or transformed by the local line discipline before the daemon can
// forward them to remote tmux. Raw mode makes the relay behave like the peer
// relay: every byte from Ghostty becomes immediate tmux input.
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
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;

        let set = unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) };
        if set != 0 {
            return Self { original: None };
        }

        Self {
            original: Some(original),
        }
    }
}

impl Drop for RawStdinGuard {
    fn drop(&mut self) {
        if let Some(ref tio) = self.original {
            unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, tio) };
        }
    }
}

/// Send multiplexer.tmux.resize for the given surface, using whatever size
/// the controlling PTY reports right now. Best-effort; errors are swallowed
/// so a resize miss never tears down the subscribe loop.
async fn push_resize(sock: &std::path::Path, surface_id: &str) {
    if let Some((cols, rows)) = current_winsize() {
        let _ = rpc(
            sock,
            "multiplexer.tmux.resize",
            json!({
                "surface_id": surface_id,
                "cols": cols,
                "rows": rows,
            }),
        )
        .await;
    }
}

fn daemon_sock() -> PathBuf {
    std::env::var("TERMMESH_DAEMON_UNIX_PATH")
        .or_else(|_| std::env::var("TERMMESH_DAEMON_SOCKET"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp/term-meshd.sock"))
}

async fn rpc(sock: &std::path::Path, method: &str, params: Value) -> Result<Value> {
    let stream = UnixStream::connect(sock)
        .await
        .map_err(|e| anyhow!("connect {}: {e}", sock.display()))?;
    let (reader, mut writer) = stream.into_split();
    let req = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
    let mut line = serde_json::to_string(&req)?;
    line.push('\n');
    writer.write_all(line.as_bytes()).await?;
    writer.flush().await?;
    let mut buf = BufReader::new(reader);
    let mut resp = String::new();
    buf.read_line(&mut resp).await?;
    let v: Value = serde_json::from_str(resp.trim()).map_err(|e| anyhow!("parse: {e}"))?;
    if let Some(err) = v.get("error").filter(|e| !e.is_null()) {
        return Err(anyhow!("RPC error: {err}"));
    }
    Ok(v)
}

fn decode_hex(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .filter_map(|i| u8::from_str_radix(hex.get(i..i + 2).unwrap_or("xx"), 16).ok())
        .collect()
}

async fn send_input(sock: &std::path::Path, surface_id: &str, bytes: &[u8]) -> Result<()> {
    if bytes.is_empty() {
        return Ok(());
    }

    // The current daemon RPC accepts `text`. PTY keyboard input is normally
    // UTF-8/control/escape bytes, all representable in a JSON string. Invalid
    // UTF-8 is replaced rather than dropping the whole chunk.
    let text = String::from_utf8_lossy(bytes).into_owned();
    rpc(
        sock,
        "multiplexer.tmux.input",
        json!({
            "surface_id": surface_id,
            "text": text,
        }),
    )
    .await?;
    Ok(())
}

async fn forward_stdin_to_daemon<R>(mut stdin: R, sock: PathBuf, surface_id: String) -> Result<()>
where
    R: AsyncRead + Unpin,
{
    let mut buf = [0u8; 4096];
    loop {
        let n = stdin.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        send_input(&sock, &surface_id, &buf[..n]).await?;
    }
    Ok(())
}

async fn subscribe_output_to_writer<W>(
    sock: PathBuf,
    surface_id: String,
    mut stdout: W,
) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let sub_stream = UnixStream::connect(&sock)
        .await
        .map_err(|e| anyhow!("subscribe connect: {e}"))?;
    let (sub_reader, mut sub_writer) = sub_stream.into_split();
    let req = json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "multiplexer.tmux.subscribe",
        "params": { "surface_id": &surface_id },
    });
    let mut line = serde_json::to_string(&req)?;
    line.push('\n');
    sub_writer.write_all(line.as_bytes()).await?;
    sub_writer.flush().await?;

    let mut sub_buf = BufReader::new(sub_reader);

    // Read and discard the ACK line.
    let mut ack = String::new();
    sub_buf.read_line(&mut ack).await?;

    // Pipe decoded PTY bytes to stdout for Ghostty to render.
    let mut line_buf = String::new();
    loop {
        line_buf.clear();
        match sub_buf.read_line(&mut line_buf).await {
            Ok(0) => break,
            Ok(_) => {
                let v: Value = match serde_json::from_str(line_buf.trim()) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                if v["kind"] == "output" {
                    let hex = v["bytes_hex"].as_str().unwrap_or("");
                    let bytes = decode_hex(hex);
                    if !bytes.is_empty() {
                        stdout.write_all(&bytes).await?;
                        stdout.flush().await?;
                    }
                }
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let _raw_stdin_guard = RawStdinGuard::enable();
    {
        let mut stdout = tokio::io::stdout();
        stdout.write_all(b"\x1b[2J\x1b[H").await?;
        stdout.flush().await?;
    }

    let host =
        std::env::var("TERMMESH_TMUX_HOST").unwrap_or_else(|_| "ubuntu@100.70.102.125".into());
    let session =
        std::env::var("TERMMESH_TMUX_SESSION").unwrap_or_else(|_| "feat-tmux-remote".into());
    let sock = daemon_sock();

    // Step 1: Attach — registers the tmux session in the daemon.
    let attach = rpc(
        &sock,
        "multiplexer.tmux.attach",
        json!({
            "host": host,
            "session": session,
        }),
    )
    .await?;
    let surface_id = attach["result"]["surface_id"]
        .as_str()
        .ok_or_else(|| anyhow!("no surface_id in attach response"))?
        .to_string();

    // Step 1b: push the local PTY size to tmux immediately so the remote
    // pane redraws at our actual width/height instead of tmux's
    // smallest-client default. Without this the claude TUI inside the
    // remote pane renders against 80x24 (or the previous client's size)
    // and the result looks "broken" with stretched separators.
    push_resize(&sock, &surface_id).await;

    // Step 1c: seed the screen with the current pane content so the TUI
    // renders immediately (ADR 0002 "scrollback seed").  Called after
    // push_resize so tmux already knows our actual terminal size and the
    // captured screen is rendered at the right width.  Best-effort:
    // errors are silently ignored so attach is never disrupted.
    if let Ok(cap) = rpc(
        &sock,
        "multiplexer.tmux.capture",
        json!({ "surface_id": &surface_id }),
    )
    .await
    {
        let hex = cap["result"]["bytes_hex"].as_str().unwrap_or("");
        let seed_bytes = decode_hex(hex);
        if !seed_bytes.is_empty() {
            let mut stdout = tokio::io::stdout();
            let _ = stdout.write_all(&seed_bytes).await;
            let _ = stdout.flush().await;
        }
    }

    // Step 1d: keep the remote pane in sync when the local window resizes.
    // SIGWINCH fires on every NSWindow drag. We re-emit a resize RPC and
    // let the daemon translate it into `refresh-client -C cols x rows`.
    let resize_sock = sock.clone();
    let resize_sid = surface_id.clone();
    tokio::spawn(async move {
        let Ok(mut wch) = signal(SignalKind::window_change()) else {
            return;
        };
        while wch.recv().await.is_some() {
            push_resize(&resize_sock, &resize_sid).await;
        }
    });

    // Step 2: Forward Ghostty PTY stdin to the daemon while the subscribe
    // connection independently streams tmux output back to stdout.
    let input_sock = sock.clone();
    let input_sid = surface_id.clone();
    tokio::spawn(async move {
        if let Err(e) = forward_stdin_to_daemon(tokio::io::stdin(), input_sock, input_sid).await {
            eprintln!("tmux relay input stopped: {e}");
        }
    });

    // Step 3: Open long-lived subscribe connection and pipe decoded PTY bytes
    // to stdout for Ghostty to render.
    let subscribe_result =
        subscribe_output_to_writer(sock.clone(), surface_id.clone(), tokio::io::stdout()).await;

    // Cleanup: detach on exit.
    let _ = rpc(
        &sock,
        "multiplexer.tmux.detach",
        json!({ "surface_id": surface_id }),
    )
    .await;

    subscribe_result?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::UnixListener;
    use tokio::sync::mpsc;
    use tokio::time::{sleep, timeout, Duration};

    fn spawn_mock_daemon() -> (
        tempfile::TempDir,
        PathBuf,
        mpsc::UnboundedReceiver<Value>,
        tokio::task::JoinHandle<()>,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("daemon.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        let (tx, rx) = mpsc::unbounded_channel();

        let handle = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    break;
                };
                let tx = tx.clone();
                tokio::spawn(async move {
                    let (reader, mut writer) = stream.into_split();
                    let mut buf = BufReader::new(reader);
                    let mut line = String::new();
                    if buf.read_line(&mut line).await.unwrap_or(0) == 0 {
                        return;
                    }
                    let req: Value = serde_json::from_str(line.trim()).unwrap();
                    let method = req["method"].as_str().unwrap_or("");
                    let _ = tx.send(req.clone());

                    if method == "multiplexer.tmux.subscribe" {
                        writer.write_all(br#"{"id":1,"result":{"status":"subscribed","surface_id":"surf-1"},"error":null}"#).await.unwrap();
                        writer.write_all(b"\n").await.unwrap();
                        writer.flush().await.unwrap();
                        sleep(Duration::from_millis(40)).await;
                        writer
                            .write_all(
                                br#"{"kind":"output","surface_id":"surf-1","bytes_hex":"6f7574"}"#,
                            )
                            .await
                            .unwrap();
                        writer.write_all(b"\n").await.unwrap();
                        let _ = writer.flush().await;
                    } else {
                        writer
                            .write_all(br#"{"id":1,"result":{"ok":true},"error":null}"#)
                            .await
                            .unwrap();
                        writer.write_all(b"\n").await.unwrap();
                        let _ = writer.flush().await;
                    }
                });
            }
        });

        (dir, sock, rx, handle)
    }

    #[tokio::test]
    async fn stdin_reader_sends_input_rpc() {
        let (_dir, sock, mut rx, server) = spawn_mock_daemon();
        let (input_reader, mut input_writer) = tokio::io::duplex(64);

        input_writer.write_all(b"abc\r").await.unwrap();
        input_writer.shutdown().await.unwrap();

        forward_stdin_to_daemon(input_reader, sock, "surf-1".into())
            .await
            .unwrap();

        let req = timeout(Duration::from_secs(1), rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(req["method"], "multiplexer.tmux.input");
        assert_eq!(req["params"]["surface_id"], "surf-1");
        assert_eq!(req["params"]["text"], "abc\r");

        server.abort();
    }

    #[tokio::test]
    async fn stdin_reader_and_subscribe_loop_run_concurrently() {
        let (_dir, sock, mut rx, server) = spawn_mock_daemon();
        let (input_reader, mut input_writer) = tokio::io::duplex(64);
        let (output_reader, output_writer) = tokio::io::duplex(64);

        let input_task = tokio::spawn(forward_stdin_to_daemon(
            input_reader,
            sock.clone(),
            "surf-1".into(),
        ));
        let subscribe_task = tokio::spawn(subscribe_output_to_writer(
            sock,
            "surf-1".into(),
            output_writer,
        ));

        input_writer.write_all(b"x").await.unwrap();
        input_writer.shutdown().await.unwrap();

        let mut output_reader = output_reader;
        let mut rendered = [0u8; 3];
        timeout(
            Duration::from_secs(1),
            output_reader.read_exact(&mut rendered),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(&rendered, b"out");

        input_task.await.unwrap().unwrap();
        subscribe_task.await.unwrap().unwrap();

        let mut methods = Vec::new();
        for _ in 0..2 {
            let req = timeout(Duration::from_secs(1), rx.recv())
                .await
                .unwrap()
                .unwrap();
            methods.push(req["method"].as_str().unwrap().to_string());
        }
        methods.sort();
        assert_eq!(
            methods,
            vec!["multiplexer.tmux.input", "multiplexer.tmux.subscribe"]
        );

        server.abort();
    }
}
