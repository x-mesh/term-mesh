//! Minimal JSON-RPC line client for the term-mesh app Unix socket.
//!
//! One request per connection, newline-delimited JSON, the same shape
//! `tests_v2/termmesh.py` and `http.rs::rpc_team_socket` speak. Kept free of
//! other crate modules so `tests/mobile_http.rs` can include it with `#[path]`.

use serde_json::Value;
use std::fmt;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::time::timeout;

/// Connect + write budget. The app answers control RPCs off-main, so a
/// healthy socket responds well inside this.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
/// Read budget. `team.read` on a large scrollback is the slowest caller.
pub const READ_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RpcFailure {
    /// Could not connect: the app is not running or the socket path is stale.
    Unavailable(String),
    /// Connected, but the exchange broke (timeout, EOF, malformed reply).
    Transport(String),
    /// The app answered with an error object. `code` is the app's v2 code
    /// (`not_found`, `invalid_params`, `unavailable`, ...).
    Rpc { code: String, message: String },
}

impl RpcFailure {
    pub fn code(&self) -> Option<&str> {
        match self {
            RpcFailure::Rpc { code, .. } => Some(code.as_str()),
            _ => None,
        }
    }
}

impl fmt::Display for RpcFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RpcFailure::Unavailable(m) => write!(f, "app socket unavailable: {m}"),
            RpcFailure::Transport(m) => write!(f, "app socket transport failure: {m}"),
            RpcFailure::Rpc { code, message } => write!(f, "{code}: {message}"),
        }
    }
}

/// Send one request and return its `result`.
pub async fn call(socket_path: &str, method: &str, params: Value) -> Result<Value, RpcFailure> {
    let stream = timeout(CONNECT_TIMEOUT, UnixStream::connect(socket_path))
        .await
        .map_err(|_| RpcFailure::Unavailable("connect timed out".into()))?
        .map_err(|e| RpcFailure::Unavailable(e.to_string()))?;
    let mut stream = stream;
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });
    let payload = format!("{request}\n");
    timeout(CONNECT_TIMEOUT, stream.write_all(payload.as_bytes()))
        .await
        .map_err(|_| RpcFailure::Transport("write timed out".into()))?
        .map_err(|e| RpcFailure::Transport(format!("write failed: {e}")))?;

    let mut reader = BufReader::new(stream);
    let mut empty_lines = 0;
    let line = loop {
        let mut line = String::new();
        let bytes = timeout(READ_TIMEOUT, reader.read_line(&mut line))
            .await
            .map_err(|_| RpcFailure::Transport("read timed out".into()))?
            .map_err(|e| RpcFailure::Transport(format!("read failed: {e}")))?;
        if bytes == 0 {
            return Err(RpcFailure::Transport("closed without a response".into()));
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            empty_lines += 1;
            if empty_lines >= 8 {
                return Err(RpcFailure::Transport("only empty lines".into()));
            }
            continue;
        }
        if !trimmed.starts_with('{') {
            return Err(RpcFailure::Transport(format!("non-JSON reply: {trimmed}")));
        }
        break trimmed.to_string();
    };
    let response: Value = serde_json::from_str(&line)
        .map_err(|e| RpcFailure::Transport(format!("invalid JSON reply: {e}")))?;
    if let Some(err) = response.get("error") {
        let code = match err.get("code") {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Number(n)) => n.to_string(),
            _ => "error".to_string(),
        };
        let message = err
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("rpc error")
            .to_string();
        return Err(RpcFailure::Rpc { code, message });
    }
    Ok(response
        .get("result")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({})))
}
