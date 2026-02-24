use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

/// Synchronous JSON-RPC 2.0 client over Unix socket.
pub struct RpcClient {
    stream: UnixStream,
}

impl RpcClient {
    /// Connect to the term-meshd daemon. Returns None if the daemon is not running.
    pub fn connect() -> Option<Self> {
        let path = default_socket_path();
        let stream = UnixStream::connect(&path).ok()?;
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .ok()?;
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .ok()?;
        Some(Self { stream })
    }

    /// Send a JSON-RPC 2.0 call and return the result value.
    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });

        let mut line = serde_json::to_string(&request).map_err(|e| format!("serialize: {e}"))?;
        line.push('\n');

        self.stream
            .write_all(line.as_bytes())
            .map_err(|e| format!("write: {e}"))?;
        self.stream.flush().map_err(|e| format!("flush: {e}"))?;

        let mut reader = BufReader::new(&self.stream);
        let mut response_line = String::new();
        reader
            .read_line(&mut response_line)
            .map_err(|e| format!("read: {e}"))?;

        let resp: Value =
            serde_json::from_str(&response_line).map_err(|e| format!("parse response: {e}"))?;

        if let Some(err) = resp.get("error") {
            let msg = err
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("unknown error");
            return Err(msg.to_string());
        }

        Ok(resp.get("result").cloned().unwrap_or(Value::Null))
    }
}

fn default_socket_path() -> PathBuf {
    if let Ok(dir) = std::env::var("TMPDIR") {
        return PathBuf::from(dir).join("term-meshd.sock");
    }
    PathBuf::from("/tmp/term-meshd.sock")
}
