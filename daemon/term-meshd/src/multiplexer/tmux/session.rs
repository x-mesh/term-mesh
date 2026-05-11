//! Per ADR 0002 §"Session lifecycle" — SSH + `tmux -CC` process management.

use anyhow::{Context, Result};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{mpsc, Mutex};

use super::encoder;
use super::parser::ControlModeParser;
use crate::multiplexer::SurfaceId;

/// A live `ssh <host> tmux -CC attach -t <session>` control-mode process.
pub struct TmuxSession {
    #[allow(dead_code)]
    child: Child,
    /// Shared so `write_command` can be called from multiple tasks concurrently.
    stdin: Arc<Mutex<ChildStdin>>,
    pub output_tx: mpsc::Sender<(SurfaceId, Vec<u8>)>,
}

impl TmuxSession {
    /// Spawn `ssh <host> tmux -CC attach -t <session>` and start the stdout
    /// reader task.
    ///
    /// Requires a reachable SSH host and an existing tmux session; only
    /// exercised by integration tests tagged `#[ignore]`.
    pub async fn connect(
        host: &str,
        session: &str,
    ) -> Result<(Self, mpsc::Receiver<(SurfaceId, Vec<u8>)>)> {
        let mut child = Command::new("ssh")
            .args([
                "-tt",
                "-o",
                "LogLevel=QUIET",
                "-o",
                "StrictHostKeyChecking=accept-new",
                host,
                "tmux",
                "-CC",
                "attach",
                "-t",
                session,
            ])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("failed to spawn ssh tmux -CC")?;

        let stdin = child.stdin.take().context("missing stdin")?;
        let stdout = child.stdout.take().context("missing stdout")?;
        let (tx, rx) = mpsc::channel(4096);
        let tx_clone = tx.clone();
        let stdin = Arc::new(Mutex::new(stdin));
        let reader_stdin = Arc::clone(&stdin);

        // Stdout reader task: feed lines to the parser and forward Output events.
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            let mut parser = ControlModeParser::new();
            let mut line = Vec::new();
            loop {
                line.clear();
                let n = match reader.read_until(b'\n', &mut line).await {
                    Ok(n) => n,
                    Err(_) => break,
                };
                if n == 0 {
                    break;
                }
                if line.ends_with(b"\n") {
                    line.pop();
                }
                if line.ends_with(b"\r") {
                    line.pop();
                }
                for ev in parser.feed_line_bytes(&line) {
                    use super::parser::TmuxEvent;
                    match ev {
                        TmuxEvent::Output { pane_id, bytes } => {
                            let sid = SurfaceId(pane_id);
                            let _ = tx_clone.send((sid, bytes)).await;
                        }
                        TmuxEvent::Pause { pane_id } => {
                            let cmd = encoder::refresh_client_continue(&pane_id);
                            let mut g = reader_stdin.lock().await;
                            let _ = g.write_all(cmd.as_bytes()).await;
                            let _ = g.write_all(b"\n").await;
                            let _ = g.flush().await;
                        }
                        _ => {}
                    }
                }
            }
        });

        Ok((
            TmuxSession {
                child,
                stdin,
                output_tx: tx,
            },
            rx,
        ))
    }

    /// Write a single tmux control command to stdin (appends `\n`).  Shared,
    /// concurrent-safe; multiple callers serialize through the inner mutex.
    pub async fn write_command(&self, cmd: &str) -> Result<()> {
        let mut g = self.stdin.lock().await;
        g.write_all(cmd.as_bytes()).await?;
        g.write_all(b"\n").await?;
        g.flush().await.context("flush tmux stdin")
    }

    /// Test-only constructor — builds a `TmuxSession` from pre-spawned parts
    /// so tests can use a fake process (e.g. `cat`) without SSH.
    #[cfg(test)]
    pub(crate) fn from_parts(
        child: Child,
        stdin: ChildStdin,
        output_tx: mpsc::Sender<(SurfaceId, Vec<u8>)>,
    ) -> Self {
        Self {
            child,
            stdin: Arc::new(Mutex::new(stdin)),
            output_tx,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::AsyncBufReadExt;

    /// Verify that `write_command` sends the command followed by a newline.
    /// Uses a local `cat` process as a fake tmux stdin consumer.
    #[tokio::test]
    async fn write_command_sends_newline_terminated_bytes() {
        let mut child = Command::new("cat")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, _rx) = mpsc::channel(1);

        let sess = TmuxSession::from_parts(child, stdin, tx);
        sess.write_command("send-keys -t %1 -H 41 42")
            .await
            .unwrap();

        let mut reader = BufReader::new(stdout).lines();
        let line = tokio::time::timeout(Duration::from_secs(1), reader.next_line())
            .await
            .expect("timeout")
            .expect("io error")
            .expect("eof");
        assert_eq!(line, "send-keys -t %1 -H 41 42");
    }

    /// Integration test: requires a live SSH host with a running tmux session.
    #[tokio::test]
    #[ignore]
    async fn connect_to_real_host() {
        let (sess, _rx) = TmuxSession::connect("ubuntu@100.70.102.125", "feat-tmux-remote")
            .await
            .expect("connect failed");
        sess.write_command("display-message -p 'hello from test'")
            .await
            .unwrap();
    }
}
