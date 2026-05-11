//! Per ADR 0002 §"Session lifecycle" — SSH + `tmux -CC` process management.
//!
//! Phase 1.0: `connect()` is a stub; the actual SSH invocation is guarded by
//! `#[allow(dead_code)]` and marked `#[ignore]` in tests so CI passes without
//! a real remote host.  Integration tests require a live SSH target.

use anyhow::{Context, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;

use super::parser::ControlModeParser;
use crate::multiplexer::SurfaceId;

/// A live `ssh <host> tmux -CC attach -t <session>` control-mode process.
pub struct TmuxSession {
    #[allow(dead_code)]
    child: Child,
    stdin: ChildStdin,
    /// Sender half of the PTY byte channel; the receiver is vended to callers
    /// of `TmuxControlBackend::attach_surface`.
    pub output_tx: mpsc::Sender<(SurfaceId, Vec<u8>)>,
}

impl TmuxSession {
    /// Spawn `ssh <host> tmux -CC attach -t <session>` and start the stdout
    /// reader task.
    ///
    /// This function is the integration entry-point.  It requires a reachable
    /// SSH host and an existing tmux session, so it is only exercised by
    /// integration tests tagged `#[ignore]`.
    pub async fn connect(host: &str, session: &str) -> Result<(Self, mpsc::Receiver<(SurfaceId, Vec<u8>)>)> {
        let mut child = Command::new("ssh")
            .args([
                "-o", "LogLevel=QUIET",
                "-o", "StrictHostKeyChecking=accept-new",
                host,
                "tmux", "-CC", "attach", "-t", session,
            ])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .context("failed to spawn ssh tmux -CC")?;

        let stdin = child.stdin.take().context("missing stdin")?;
        let stdout = child.stdout.take().context("missing stdout")?;
        let (tx, rx) = mpsc::channel(256);
        let tx_clone = tx.clone();

        // Stdout reader task: feed lines to the parser and forward Output events.
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout).lines();
            let mut parser = ControlModeParser::new();
            while let Ok(Some(line)) = reader.next_line().await {
                for ev in parser.feed_line(&line) {
                    use super::parser::TmuxEvent;
                    if let TmuxEvent::Output { pane_id, bytes } = ev {
                        let sid = SurfaceId(pane_id);
                        let _ = tx_clone.send((sid, bytes)).await;
                    }
                }
            }
        });

        Ok((TmuxSession { child, stdin, output_tx: tx }, rx))
    }

    /// Write a control command to tmux stdin (appends newline).
    pub async fn send_command(&mut self, cmd: &str) -> Result<()> {
        self.stdin
            .write_all(format!("{}\n", cmd).as_bytes())
            .await
            .context("failed to write command to tmux stdin")
    }
}

#[cfg(test)]
mod tests {
    /// Integration test: requires a live SSH host with a running tmux session.
    /// Skipped in normal CI runs.
    #[tokio::test]
    #[ignore]
    async fn connect_to_real_host() {
        use super::*;
        let (mut session, _rx) =
            TmuxSession::connect("ubuntu@100.70.102.125", "feat-tmux-remote")
                .await
                .expect("connect failed");
        session.send_command("display-message -p 'hello from test'").await.unwrap();
    }
}
