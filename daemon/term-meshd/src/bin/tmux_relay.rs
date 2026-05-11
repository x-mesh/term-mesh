// term-meshd-tmux-relay — bridges multiplexer.tmux.subscribe output to stdout.
//
// Ghostty spawns this binary as the "shell" for a TmuxRelayWindowController.
// The binary connects to term-meshd, attaches to the remote tmux session,
// subscribes to the output stream, decodes hex-encoded frames, and writes
// raw PTY bytes to stdout — which Ghostty renders in the terminal surface.
//
// Env vars:
//   TERMMESH_DAEMON_UNIX_PATH  — path to term-meshd socket (required)
//   TERMMESH_TMUX_HOST         — SSH host (e.g. ubuntu@100.70.102.125)
//   TERMMESH_TMUX_SESSION      — tmux session name

use std::path::PathBuf;

use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

fn daemon_sock() -> PathBuf {
    std::env::var("TERMMESH_DAEMON_UNIX_PATH")
        .or_else(|_| std::env::var("TERMMESH_DAEMON_SOCKET"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp/term-meshd.sock"))
}

async fn rpc(sock: &std::path::Path, method: &str, params: Value) -> Result<Value> {
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
        .map_err(|e| anyhow!("parse: {e}"))?;
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

#[tokio::main]
async fn main() -> Result<()> {
    let host = std::env::var("TERMMESH_TMUX_HOST")
        .unwrap_or_else(|_| "ubuntu@100.70.102.125".into());
    let session = std::env::var("TERMMESH_TMUX_SESSION")
        .unwrap_or_else(|_| "feat-tmux-remote".into());
    let sock = daemon_sock();

    // Step 1: Attach — registers the tmux session in the daemon.
    let attach = rpc(&sock, "multiplexer.tmux.attach", json!({
        "host": host,
        "session": session,
    })).await?;
    let surface_id = attach["result"]["surface_id"]
        .as_str()
        .ok_or_else(|| anyhow!("no surface_id in attach response"))?
        .to_string();

    // Step 2: Open long-lived subscribe connection.
    let sub_stream = UnixStream::connect(&sock).await
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

    // Step 3: Pipe decoded PTY bytes to stdout for Ghostty to render.
    let mut stdout = tokio::io::stdout();
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
                        if stdout.write_all(&bytes).await.is_err() { break; }
                        let _ = stdout.flush().await;
                    }
                }
            }
            Err(_) => break,
        }
    }

    // Cleanup: detach on exit.
    let _ = rpc(&sock, "multiplexer.tmux.detach", json!({ "surface_id": surface_id })).await;

    Ok(())
}
