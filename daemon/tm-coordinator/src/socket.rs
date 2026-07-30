use crate::api::Api;
use crate::model::IntentEvent;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::os::fd::AsRawFd;
use std::path::Path;
use std::sync::Arc;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader, WriteHalf};
use tokio::net::{UnixListener, UnixStream};
use tokio::time::{interval, Duration};

const MAX_FRAME: usize = 64 * 1024;
const MAX_EVENT_FRAME: usize = 4 * 1024;

/// Default ceiling on concurrent connections, mirroring the sibling peer
/// server's `MAX_PEER_CONNECTIONS`.
///
/// Accepting without a bound let one caller — or one runaway script — spawn
/// tasks and file descriptors until something else on the machine broke,
/// with nothing to point at. A limit turns that into a log line naming the
/// ceiling. Override with `TERMMESH_COORDINATOR_MAX_CONNECTIONS`.
const DEFAULT_MAX_CONNECTIONS: usize = 64;
const MAX_CONNECTIONS_VAR: &str = "TERMMESH_COORDINATOR_MAX_CONNECTIONS";

/// Split from the env read so the parse can be tested. A value that is not a
/// positive integer is ignored rather than refusing to start: a coordinator
/// up with the wrong ceiling is easier to notice and correct than one that
/// never came up.
fn parse_max_connections(raw: Option<&str>) -> usize {
    let Some(raw) = raw else {
        return DEFAULT_MAX_CONNECTIONS;
    };
    match raw.trim().parse::<usize>() {
        Ok(value) if value > 0 => value,
        _ => {
            tracing::warn!(
                "{MAX_CONNECTIONS_VAR}={raw:?} is not a positive integer; using {DEFAULT_MAX_CONNECTIONS}"
            );
            DEFAULT_MAX_CONNECTIONS
        }
    }
}

#[derive(Debug, Deserialize)]
struct Request {
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Serialize)]
struct Response {
    id: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
struct RpcError {
    code: i32,
    message: String,
}

pub async fn serve(api: Arc<Api>, path: &Path) -> Result<()> {
    if path.exists() {
        let _ = std::fs::remove_file(path);
    }
    let listener = bind_with_tight_umask(path)?;
    let max_connections = parse_max_connections(std::env::var(MAX_CONNECTIONS_VAR).ok().as_deref());
    tracing::info!("coordinator connection ceiling: {max_connections}");
    let permits = Arc::new(tokio::sync::Semaphore::new(max_connections));
    loop {
        let (stream, _) = listener.accept().await?;
        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            tracing::warn!(
                "coordinator connection limit reached ({max_connections}); closing new client — raise {MAX_CONNECTIONS_VAR} to allow more"
            );
            drop(stream);
            continue;
        };
        let api = api.clone();
        tokio::spawn(async move {
            let _permit = permit;
            if let Err(error) = handle_connection(api, stream).await {
                tracing::debug!(%error, "coordinator socket connection ended");
            }
        });
    }
}

async fn handle_connection(api: Arc<Api>, stream: UnixStream) -> Result<()> {
    enforce_owner_uid(&stream)?;
    let (reader, mut writer) = tokio::io::split(stream);
    let mut reader = BufReader::new(reader);
    loop {
        let line = match read_bounded_line(&mut reader).await? {
            Some(line) => line,
            None => return Ok(()),
        };
        if line.len() > MAX_FRAME {
            write_response(&mut writer, None, Err("REQUEST_TOO_LARGE".to_string())).await?;
            return Ok(());
        }
        let req: Request = match serde_json::from_str(&line) {
            Ok(req) => req,
            Err(error) => {
                write_response(&mut writer, None, Err(format!("PARSE_ERROR: {error}"))).await?;
                continue;
            }
        };
        if req.method == "events.subscribe" {
            write_response(
                &mut writer,
                req.id.clone(),
                Ok(serde_json::json!({"subscribed": true})),
            )
            .await?;
            stream_events(api, writer).await?;
            return Ok(());
        }
        let id = req.id.clone();
        // JSON-RPC lets a caller omit `params` entirely, and handlers whose
        // fields are all optional (task.list) would otherwise reject the
        // request with "invalid type: null". One failing call sinks a whole
        // client snapshot, which is how a perfectly healthy coordinator ended
        // up reported as offline.
        let params = if req.params.is_null() {
            Value::Object(Default::default())
        } else {
            req.params
        };
        let result = api.handle(&req.method, params).map_err(|e| e.to_string());
        write_response(&mut writer, id, result).await?;
    }
}

async fn read_bounded_line<R>(reader: &mut R) -> Result<Option<String>>
where
    R: AsyncBufRead + Unpin,
{
    let mut frame = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            if frame.is_empty() {
                return Ok(None);
            }
            return Ok(Some(String::from_utf8_lossy(&frame).into_owned()));
        }
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            let take = newline + 1;
            if frame.len() + take > MAX_FRAME {
                reader.consume(take);
                return Ok(Some(" ".repeat(MAX_FRAME + 1)));
            }
            frame.extend_from_slice(&available[..take]);
            reader.consume(take);
            return Ok(Some(String::from_utf8_lossy(&frame).into_owned()));
        }
        if frame.len() + available.len() > MAX_FRAME {
            let take = MAX_FRAME + 1 - frame.len();
            frame.extend_from_slice(&available[..take]);
            reader.consume(take);
            return Ok(Some(" ".repeat(MAX_FRAME + 1)));
        }
        let len = available.len();
        frame.extend_from_slice(available);
        reader.consume(len);
    }
}

async fn stream_events(api: Arc<Api>, mut writer: WriteHalf<UnixStream>) -> Result<()> {
    let mut rx = api.subscribe();
    let mut keepalive = interval(Duration::from_secs(30));
    loop {
        tokio::select! {
            event = rx.recv() => match event {
                Ok(event) => write_event(&mut writer, &event).await?,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    let gap = serde_json::json!({"kind":"event_gap","missed":n});
                    writer.write_all(serde_json::to_string(&gap)?.as_bytes()).await?;
                    writer.write_all(b"\n").await?;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return Ok(()),
            },
            _ = keepalive.tick() => {
                writer.write_all(b"{\"kind\":\"keepalive\"}\n").await?;
            }
        }
    }
}

async fn write_event(writer: &mut WriteHalf<UnixStream>, event: &IntentEvent) -> Result<()> {
    let json = serde_json::to_string(event)?;
    if json.len() > MAX_EVENT_FRAME {
        writer
            .write_all(b"{\"kind\":\"error\",\"code\":\"event_too_large\",\"dropped\":true}\n")
            .await?;
    } else {
        writer.write_all(json.as_bytes()).await?;
        writer.write_all(b"\n").await?;
    }
    Ok(())
}

async fn write_response(
    writer: &mut WriteHalf<UnixStream>,
    id: Option<Value>,
    result: std::result::Result<Value, String>,
) -> Result<()> {
    let response = match result {
        Ok(result) => Response {
            id,
            result: Some(result),
            error: None,
        },
        Err(message) => Response {
            id,
            result: None,
            error: Some(RpcError {
                code: -32000,
                message,
            }),
        },
    };
    let mut encoded = serde_json::to_vec(&response)?;
    if encoded.len() > MAX_FRAME {
        encoded = serde_json::to_vec(&Response {
            id: response.id,
            result: None,
            error: Some(RpcError {
                code: -32001,
                message: "RESPONSE_TOO_LARGE".to_string(),
            }),
        })?;
    }
    writer.write_all(&encoded).await?;
    writer.write_all(b"\n").await?;
    Ok(())
}

/// Refuse to bind under a directory somebody else controls.
///
/// The socket file itself is created 0600, but that says nothing about the
/// directory holding it: a parent owned by another user can have the entry
/// swapped between bind and connect. The sibling peer server already refuses
/// this (`term-meshd/src/peer/server.rs::harden_parent_directory`), and the
/// path here is env-overridable to anywhere, so the same check belongs here.
///
/// A world-writable directory with the sticky bit is the system temp dir —
/// the kernel already stops one user removing another's entries there, which
/// is the property being asked for.
#[cfg(unix)]
fn harden_parent_directory(parent: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    if !parent.exists() {
        std::fs::create_dir_all(parent)?;
    }
    let meta = std::fs::metadata(parent)?;
    if !meta.is_dir() {
        anyhow::bail!("coordinator socket parent {} is not a directory", parent.display());
    }
    let owner_uid = unsafe { libc::geteuid() };
    let mode = meta.mode();
    if meta.uid() == owner_uid {
        if mode & 0o777 != 0o700 {
            let mut perms = meta.permissions();
            perms.set_mode(0o700);
            std::fs::set_permissions(parent, perms)?;
        }
    } else if mode & 0o1000 == 0 {
        anyhow::bail!(
            "coordinator socket parent {} is owned by uid {}, not {}; refusing to bind",
            parent.display(),
            meta.uid(),
            owner_uid
        );
    }
    Ok(())
}

#[cfg(unix)]
fn bind_with_tight_umask(path: &Path) -> Result<UnixListener> {
    if let Some(parent) = path.parent() {
        harden_parent_directory(parent)?;
    }
    struct UmaskGuard(libc::mode_t);
    impl Drop for UmaskGuard {
        fn drop(&mut self) {
            unsafe {
                libc::umask(self.0);
            }
        }
    }
    let old = unsafe { libc::umask(0o177) };
    let _guard = UmaskGuard(old);
    let listener = UnixListener::bind(path).with_context(|| format!("bind {}", path.display()))?;
    std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    Ok(listener)
}

#[cfg(target_os = "macos")]
fn enforce_owner_uid(stream: &UnixStream) -> Result<()> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error()).context("getpeereid");
    }
    if uid != unsafe { libc::geteuid() } {
        anyhow::bail!("peer uid rejected");
    }
    Ok(())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn enforce_owner_uid(stream: &UnixStream) -> Result<()> {
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cred as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error()).context("SO_PEERCRED");
    }
    if cred.uid != unsafe { libc::geteuid() } {
        anyhow::bail!("peer uid rejected");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A ceiling read from the environment, and the reasons to ignore one.
    ///
    /// Zero is rejected rather than honoured: a semaphore with no permits
    /// refuses every client, which is indistinguishable from a coordinator
    /// that never started.
    #[test]
    fn connection_ceiling_falls_back_on_anything_unusable() {
        assert_eq!(parse_max_connections(Some("128")), 128);
        assert_eq!(parse_max_connections(Some("  128  ")), 128);
        for unusable in [None, Some(""), Some("0"), Some("-1"), Some("lots")] {
            assert_eq!(
                parse_max_connections(unusable),
                DEFAULT_MAX_CONNECTIONS,
                "expected fallback for {unusable:?}"
            );
        }
    }
}
