// Phase 1.3 RPC smoke test — attach → subscribe → input → detach round-trip.
//
// Verifies that the daemon's multiplexer.tmux.{attach,subscribe,input,detach}
// RPCs all work end-to-end against a real remote tmux session.
//
// Usage:
//   cargo run --release --example tmux_rpc_smoke -- \
//     [--input <text>] <ssh-host> <tmux-session> [duration-secs]
//
// Requires:
//   - term-meshd running (point TERMMESH_DAEMON_UNIX_PATH at its socket)
//   - Reachable SSH host with an active tmux session

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};

// ── Socket helpers ────────────────────────────────────────────────────────────

fn daemon_sock() -> PathBuf {
    if let Ok(p) = std::env::var("TERMMESH_DAEMON_UNIX_PATH") {
        return PathBuf::from(p);
    }
    if let Ok(p) = std::env::var("TERMMESH_DAEMON_SOCKET") {
        return PathBuf::from(p);
    }
    // Mirror detect_daemon_socket() from tm-agent.
    if let Ok(home) = std::env::var("HOME") {
        let p = PathBuf::from(format!("{home}/.local/share/term-mesh/term-meshd.sock"));
        if p.exists() { return p; }
    }
    PathBuf::from("/tmp/term-meshd.sock")
}

/// One-shot JSON-RPC call: connect, write, read one response line.
async fn rpc(sock: &Path, method: &str, params: Value) -> Result<Value> {
    let stream = UnixStream::connect(sock).await
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
    let v: Value = serde_json::from_str(resp.trim())
        .map_err(|e| anyhow!("parse response: {e}: {resp}"))?;
    if let Some(err) = v.get("error").filter(|e| !e.is_null()) {
        return Err(anyhow!("RPC error: {err}"));
    }
    Ok(v)
}

/// Open a long-lived subscribe connection.  Returns the writer (kept alive to
/// prevent EOF on the server's reader) and a BufReader over the response stream.
async fn open_subscribe(
    sock: &Path,
    surface_id: &str,
    timeout_ms: u64,
) -> Result<(
    tokio::net::unix::OwnedWriteHalf,
    BufReader<tokio::net::unix::OwnedReadHalf>,
)> {
    let stream = UnixStream::connect(sock).await
        .map_err(|e| anyhow!("subscribe connect: {e}"))?;
    let (reader, mut writer) = stream.into_split();
    let req = json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "multiplexer.tmux.subscribe",
        "params": { "surface_id": surface_id, "timeout_ms": timeout_ms },
    });
    let mut line = serde_json::to_string(&req)?;
    line.push('\n');
    writer.write_all(line.as_bytes()).await?;
    writer.flush().await?;
    Ok((writer, BufReader::new(reader)))
}

// ── Display helpers ───────────────────────────────────────────────────────────

fn hex_preview(hex: &str) -> String {
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .filter_map(|i| u8::from_str_radix(hex.get(i..i + 2).unwrap_or("xx"), 16).ok())
        .collect();
    bytes
        .iter()
        .map(|&b| match b {
            0x1b => "^[".to_string(),
            0x07 => "^G".to_string(),
            0x0d => "\\r".to_string(),
            0x0a => "\\n".to_string(),
            b if b.is_ascii_graphic() || b == b' ' => (b as char).to_string(),
            _ => format!("\\x{b:02x}"),
        })
        .collect::<String>()
}

#[cfg(test)]
mod tests {
    use super::hex_preview;

    #[test]
    fn hex_preview_printable() {
        assert_eq!(hex_preview("68656c6c6f"), "hello");
    }

    #[test]
    fn hex_preview_esc() {
        assert_eq!(hex_preview("1b5b33316d"), "^[[31m");
    }

    #[test]
    fn hex_preview_empty() {
        assert_eq!(hex_preview(""), "");
    }
}

// ── Arg parsing ───────────────────────────────────────────────────────────────

struct Config {
    host: String,
    session: String,
    duration_secs: u64,
    input_text: Option<String>,
}

fn parse_args() -> Result<Config> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let input_text = args
        .windows(2)
        .find(|w| w[0] == "--input")
        .map(|w| w[1].clone());

    let skip: std::collections::HashSet<&str> = {
        let mut s = std::collections::HashSet::new();
        s.insert("--input");
        if let Some(t) = &input_text { s.insert(t.as_str()); }
        s
    };

    let positional: Vec<&str> = args
        .iter()
        .map(|s| s.as_str())
        .filter(|s| !skip.contains(*s))
        .collect();

    if positional.len() < 2 {
        return Err(anyhow!(
            "Usage: tmux_rpc_smoke [--input <text>] <ssh-host> <tmux-session> [duration-secs]"
        ));
    }

    Ok(Config {
        host: positional[0].to_string(),
        session: positional[1].to_string(),
        duration_secs: positional.get(2).and_then(|s| s.parse().ok()).unwrap_or(8),
        input_text,
    })
}

// ── Main ──────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    let cfg = parse_args()?;
    let sock = daemon_sock();
    let duration = Duration::from_secs(cfg.duration_secs);

    println!("=== tmux_rpc_smoke ===");
    println!("  host:     {}", cfg.host);
    println!("  session:  {}", cfg.session);
    println!("  duration: {}s", cfg.duration_secs);
    println!("  input:    {}", cfg.input_text.as_deref().unwrap_or("(none)"));
    println!("  socket:   {}", sock.display());
    println!();

    // ── Step 1: attach ────────────────────────────────────────────────────────
    println!("[1] multiplexer.tmux.attach ...");
    let t0 = Instant::now();
    let attach_resp = rpc(&sock, "multiplexer.tmux.attach", json!({
        "host": cfg.host,
        "session": cfg.session,
    })).await?;
    let surface_id = attach_resp["result"]["surface_id"]
        .as_str()
        .ok_or_else(|| anyhow!("no surface_id: {attach_resp}"))?
        .to_string();
    println!("    surface_id = {surface_id}  ({:.0}ms)", t0.elapsed().as_millis());

    // ── Step 2: subscribe ─────────────────────────────────────────────────────
    println!("[2] multiplexer.tmux.subscribe ...");
    let timeout_ms = cfg.duration_secs * 1000;
    let (_sub_writer, mut sub_reader) =
        open_subscribe(&sock, &surface_id, timeout_ms).await?;

    // Read the ACK line.
    let mut ack_line = String::new();
    sub_reader.read_line(&mut ack_line).await?;
    let ack: Value = serde_json::from_str(ack_line.trim())
        .map_err(|e| anyhow!("bad ACK: {e}: {ack_line}"))?;
    if let Some(err) = ack.get("error").filter(|e| !e.is_null()) {
        return Err(anyhow!("subscribe error: {err}"));
    }
    println!("    subscribed ✓");

    // ── Step 3: reader task ───────────────────────────────────────────────────
    let (frame_tx, mut frame_rx) = mpsc::channel::<Value>(512);
    tokio::spawn(async move {
        let mut line = String::new();
        loop {
            line.clear();
            match sub_reader.read_line(&mut line).await {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    if let Ok(v) = serde_json::from_str::<Value>(line.trim()) {
                        if frame_tx.send(v).await.is_err() {
                            break;
                        }
                    }
                }
            }
        }
    });

    // ── Step 4: optional input at duration/2 ─────────────────────────────────
    let (input_sent_tx, mut input_sent_rx) = oneshot::channel::<f64>();
    if let Some(text) = cfg.input_text.clone() {
        let delay = duration / 2;
        let sock2 = sock.clone();
        let sid = surface_id.clone();
        let start = Instant::now();
        tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            println!("[3] multiplexer.tmux.input {:?} ...", text);
            // Append CR so the shell executes the command.
            let payload = format!("{text}\r");
            match rpc(&sock2, "multiplexer.tmux.input", json!({
                "surface_id": sid,
                "text": payload,
            })).await {
                Ok(_) => {
                    let elapsed = start.elapsed().as_secs_f64();
                    println!("    input sent at {elapsed:.1}s ✓");
                    let _ = input_sent_tx.send(elapsed);
                }
                Err(e) => eprintln!("    input error: {e}"),
            }
        });
    }

    // ── Step 5: collect frames until deadline ─────────────────────────────────
    let deadline = tokio::time::Instant::now() + duration;
    let mut frame_count = 0u64;
    let mut byte_count = 0u64;
    let mut last_frames: VecDeque<Value> = VecDeque::new();

    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => break,
            frame = frame_rx.recv() => {
                match frame {
                    None => break,
                    Some(v) => {
                        if v["kind"].as_str() == Some("output") {
                            frame_count += 1;
                            let hex = v["bytes_hex"].as_str().unwrap_or("");
                            byte_count += hex.len() as u64 / 2;
                            if last_frames.len() >= 5 { last_frames.pop_front(); }
                            last_frames.push_back(v);
                        }
                    }
                }
            }
        }
    }

    // Retrieve input send time (non-blocking).
    let input_at = input_sent_rx.try_recv().ok();

    // ── Step 6: detach ────────────────────────────────────────────────────────
    println!("[4] multiplexer.tmux.detach ...");
    match rpc(&sock, "multiplexer.tmux.detach", json!({ "surface_id": &surface_id })).await {
        Ok(r) => println!("    detach ✓  removed={}", r["result"]["removed"]),
        Err(e) => eprintln!("    detach error: {e}"),
    }

    // ── Summary ───────────────────────────────────────────────────────────────
    println!();
    println!("=== results ===");
    println!("  duration:    {}s", cfg.duration_secs);
    println!("  frames:      {frame_count}");
    println!("  bytes:       {byte_count}");
    println!("  input sent:  {}", input_at.map(|t| format!("{t:.1}s")).unwrap_or_else(|| "no".into()));
    println!("  last {} frames:", last_frames.len());
    for f in &last_frames {
        let hex = f["bytes_hex"].as_str().unwrap_or("");
        let preview: String = hex_preview(hex).chars().take(70).collect();
        println!("    [{}] pane={} → {preview}",
            f["kind"].as_str().unwrap_or("?"),
            f["pane_id"].as_str().unwrap_or("?"),
        );
    }

    println!();
    if frame_count >= 1 {
        println!("PASS — {frame_count} output frames received");
    } else {
        eprintln!("FAIL — 0 output frames received");
        std::process::exit(1);
    }

    Ok(())
}
