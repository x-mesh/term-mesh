//! An agent CLI whose stdio this process owns.
//!
//! Split into a trait and one real implementation so the protocol code can be
//! driven by a scripted peer in tests. The Python original relies on duck
//! typing for the same thing; naming the shape costs a few lines and makes the
//! surface a bridge may depend on explicit.

#![allow(dead_code)]

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child as OsChild, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;

use crate::location::{process_location, remote_launch_failure, RemoteEnv};
use crate::text::clamp;

/// How much of a crashed CLI's stderr is kept as an explanation.
const STDERR_LINES: usize = 40;
const STDERR_DETAIL_LIMIT: usize = 1200;

/// The persistent agent process can no longer accept protocol frames.
#[derive(Debug, Clone)]
pub struct ChildExited(pub String);

impl std::fmt::Display for ChildExited {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// What arrives from the child. `Eof` is a frame of its own rather than a
/// silence to be inferred: a reader that sees the stream end must be able to
/// say so, or a bridge waits out its whole timeout for an answer that can
/// never come.
#[derive(Debug, Clone)]
pub enum Inbound {
    Frame(Value),
    Eof,
}

pub trait Transport {
    fn send(&mut self, obj: &Value) -> Result<(), ChildExited>;
    fn recv_timeout(&self, timeout: Duration) -> Result<Inbound, RecvTimeoutError>;
    fn alive(&self) -> bool;
    fn exit_code(&self) -> Option<i32>;
    /// Why the child can no longer be spoken to, in a sentence a person can
    /// act on.
    fn failure_message(&self) -> String;
}

pub struct ProcessChild {
    process: Mutex<OsChild>,
    /// The reaped status, remembered.
    ///
    /// A child that has exited but not been waited for is a zombie, and a
    /// zombie still answers `kill(pid, 0)` — so asking the OS whether the pid
    /// exists reports a dead process as alive forever. The status has to be
    /// collected once and kept, which is what Python's `poll` does too.
    exit: Mutex<Option<i32>>,
    stdin: Option<std::process::ChildStdin>,
    inbox: Receiver<Inbound>,
    stderr_lines: Arc<Mutex<VecDeque<String>>>,
}

impl ProcessChild {
    pub fn spawn(argv: &[String], cwd: &str) -> std::io::Result<Self> {
        let located = process_location(&RemoteEnv::from_process(), argv, cwd)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
        let (program, rest) = located
            .argv
            .split_first()
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "empty argv"))?;

        let mut command = Command::new(program);
        command
            .args(rest)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(dir) = located.cwd.as_deref() {
            command.current_dir(dir);
        }
        // A nested agent CLI refuses to start when it thinks it is inside one.
        command.env_remove("CLAUDECODE");
        command.env_remove("CLAUDE_CODE_ENTRYPOINT");

        let mut process = command.spawn()?;
        let stdin = process.stdin.take();
        let stdout = process.stdout.take().expect("stdout is piped");
        let stderr = process.stderr.take().expect("stderr is piped");

        let (tx, inbox) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let line = line.trim();
                // Anything that is not a frame is the CLI talking to a human;
                // parsing it would only invent frames out of banners.
                if !line.starts_with('{') {
                    continue;
                }
                if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(line) {
                    if tx.send(Inbound::Frame(Value::Object(map))).is_err() {
                        return;
                    }
                }
            }
            let _ = tx.send(Inbound::Eof);
        });

        let stderr_lines = Arc::new(Mutex::new(VecDeque::with_capacity(STDERR_LINES)));
        let sink = Arc::clone(&stderr_lines);
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines() {
                let Ok(line) = line else { break };
                let line = line.trim().to_string();
                if line.is_empty() {
                    continue;
                }
                let mut kept = sink.lock().unwrap();
                if kept.len() == STDERR_LINES {
                    kept.pop_front();
                }
                kept.push_back(line);
            }
        });

        Ok(Self {
            process: Mutex::new(process),
            exit: Mutex::new(None),
            stdin,
            inbox,
            stderr_lines,
        })
    }

    /// Collect the child's status if it has one, and remember it.
    fn poll_exit(&self) -> Option<i32> {
        if let Some(code) = *self.exit.lock().unwrap() {
            return Some(code);
        }
        let status = self.process.lock().unwrap().try_wait().ok().flatten()?;
        let code = status.code().unwrap_or_else(|| {
            use std::os::unix::process::ExitStatusExt;
            // Negative for a signal, matching Python's `returncode`.
            -status.signal().unwrap_or(0)
        });
        *self.exit.lock().unwrap() = Some(code);
        Some(code)
    }
}

impl Transport for ProcessChild {
    fn send(&mut self, obj: &Value) -> Result<(), ChildExited> {
        if !self.alive() {
            return Err(ChildExited(self.failure_message()));
        }
        let line = serde_json::to_string(obj).map_err(|e| ChildExited(e.to_string()))?;
        let Some(stdin) = self.stdin.as_mut() else {
            return Err(ChildExited(self.failure_message()));
        };
        // A broken pipe says only that writing failed. What the caller needs
        // is why the child is gone, which is what failure_message answers.
        if writeln!(stdin, "{line}").and_then(|_| stdin.flush()).is_err() {
            return Err(ChildExited(self.failure_message()));
        }
        Ok(())
    }

    fn recv_timeout(&self, timeout: Duration) -> Result<Inbound, RecvTimeoutError> {
        self.inbox.recv_timeout(timeout)
    }

    fn alive(&self) -> bool {
        self.poll_exit().is_none()
    }

    fn exit_code(&self) -> Option<i32> {
        self.poll_exit()
    }

    fn failure_message(&self) -> String {
        let code = self.exit_code();
        let failure = remote_launch_failure(code)
            .map(str::to_string)
            .unwrap_or_else(|| match code {
                None => "agent process closed its input channel".to_string(),
                Some(c) if c < 0 => format!("agent process was killed by signal {}", -c),
                Some(c) => format!("agent process exited with code {c}"),
            });

        // Keep a bounded diagnostic tail rather than discarding the only
        // explanation a crashed CLI may have produced.
        let detail = {
            let kept = self.stderr_lines.lock().unwrap();
            clamp(
                &kept.iter().cloned().collect::<Vec<_>>().join("\n"),
                STDERR_DETAIL_LIMIT,
            )
        };
        if detail.is_empty() {
            failure
        } else {
            format!("{failure}: {detail}")
        }
    }
}

impl Drop for ProcessChild {
    fn drop(&mut self) {
        // Closing stdin first gives a CLI that watches for it the chance to
        // leave on its own terms before it is killed.
        self.stdin.take();
        let mut process = self.process.lock().unwrap();
        if process.try_wait().ok().flatten().is_none() {
            let _ = process.kill();
        }
        let _ = process.wait();
    }
}

#[cfg(test)]
pub mod testing {
    use super::*;
    use std::sync::mpsc::Sender;

    /// A CLI that says exactly what the test wrote down, and nothing else.
    pub struct ScriptedChild {
        pub sent: Arc<Mutex<Vec<Value>>>,
        inbox: Receiver<Inbound>,
        pub alive: bool,
        pub exit: Option<i32>,
        /// When set, `send` fails with this instead of recording the frame.
        pub send_failure: Option<String>,
    }

    impl ScriptedChild {
        pub fn new(frames: Vec<Value>) -> Self {
            let (tx, inbox) = mpsc::channel();
            for frame in frames {
                let _ = tx.send(Inbound::Frame(frame));
            }
            // Ending the script rather than waiting out the timeout.
            let _ = tx.send(Inbound::Eof);
            Self {
                sent: Arc::new(Mutex::new(Vec::new())),
                inbox,
                alive: true,
                exit: None,
                send_failure: None,
            }
        }

        pub fn dead(exit: i32, message: &str) -> Self {
            let mut child = Self::new(vec![]);
            child.alive = false;
            child.exit = Some(exit);
            child.send_failure = Some(message.to_string());
            child
        }

        pub fn sender(frames: Vec<Value>) -> (Self, Sender<Inbound>) {
            let (tx, inbox) = mpsc::channel();
            for frame in frames {
                let _ = tx.send(Inbound::Frame(frame));
            }
            let child = Self {
                sent: Arc::new(Mutex::new(Vec::new())),
                inbox,
                alive: true,
                exit: None,
                send_failure: None,
            };
            (child, tx)
        }
    }

    impl Transport for ScriptedChild {
        fn send(&mut self, obj: &Value) -> Result<(), ChildExited> {
            if let Some(message) = self.send_failure.as_ref() {
                return Err(ChildExited(message.clone()));
            }
            self.sent.lock().unwrap().push(obj.clone());
            Ok(())
        }

        fn recv_timeout(&self, timeout: Duration) -> Result<Inbound, RecvTimeoutError> {
            self.inbox.recv_timeout(timeout)
        }

        fn alive(&self) -> bool {
            self.alive
        }

        fn exit_code(&self) -> Option<i32> {
            self.exit
        }

        fn failure_message(&self) -> String {
            self.send_failure
                .clone()
                .unwrap_or_else(|| "agent process exited".to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn wait_until(deadline: Duration, mut done: impl FnMut() -> bool) {
        let started = Instant::now();
        while started.elapsed() < deadline {
            if done() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn send_reports_exit_code_and_stderr_instead_of_broken_pipe() {
        let argv: Vec<String> = ["/bin/sh", "-c", "echo intentional child crash >&2; exit 7"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let mut child = ProcessChild::spawn(&argv, "/tmp").expect("spawns");

        wait_until(Duration::from_secs(2), || !child.alive());
        wait_until(Duration::from_secs(2), || {
            !child.stderr_lines.lock().unwrap().is_empty()
        });

        let error = child
            .send(&serde_json::json!({"jsonrpc": "2.0", "method": "turn/start"}))
            .expect_err("a dead child cannot take a frame");

        // A broken pipe would say only that the write failed. The exit code
        // and the child's own last words are what make it actionable.
        assert!(error.0.contains("exited with code 7"), "{}", error.0);
        assert!(error.0.contains("intentional child crash"), "{}", error.0);
    }

    #[test]
    fn a_stream_that_ends_reports_eof_rather_than_going_quiet() {
        let argv: Vec<String> = ["/bin/sh", "-c", r#"echo '{"id":1,"result":{}}'"#]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let child = ProcessChild::spawn(&argv, "/tmp").expect("spawns");

        let first = child.recv_timeout(Duration::from_secs(2)).expect("a frame");
        let second = child.recv_timeout(Duration::from_secs(2)).expect("an end");

        assert!(matches!(first, Inbound::Frame(_)));
        assert!(matches!(second, Inbound::Eof));
    }

    #[test]
    fn output_that_is_not_a_frame_is_ignored_rather_than_parsed() {
        let argv: Vec<String> = [
            "/bin/sh",
            "-c",
            r#"echo 'starting up...'; echo 'not json'; echo '{"id":9,"result":{}}'"#,
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let child = ProcessChild::spawn(&argv, "/tmp").expect("spawns");

        let first = child.recv_timeout(Duration::from_secs(2)).expect("a frame");

        match first {
            Inbound::Frame(v) => assert_eq!(v["id"], 9),
            Inbound::Eof => panic!("banner lines swallowed the frame"),
        }
    }

    #[test]
    fn a_signalled_child_is_reported_as_signalled() {
        let argv: Vec<String> = ["/bin/sh", "-c", "kill -TERM $$"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let child = ProcessChild::spawn(&argv, "/tmp").expect("spawns");

        wait_until(Duration::from_secs(2), || !child.alive());

        assert!(
            child.failure_message().contains("killed by signal"),
            "{}",
            child.failure_message()
        );
    }
}
