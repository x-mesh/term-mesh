//! cursor and agy: a CLI with no stdin channel, where each turn is its own
//! process.
//!
//! This is not the terminal path in disguise. The answer arrives on stdout
//! rather than on a screen, and the process exiting *is* the end-of-turn
//! signal — plainer than any of the three protocols. What it costs is the
//! context reloaded each turn, and an id that has to be kept to stay on the
//! same thread.
//!
//! That id is the one place the two differ. Cursor puts it in the answer, so
//! it is read from the same object as everything else. agy announces it only
//! in its log file, so the bridge gives it a log to write and reads the line
//! back out — string-scraping for state, which is what this whole exercise is
//! trying to get away from, but it is a stable server log line rather than a
//! rendered screen.

#![allow(dead_code)]

use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use crate::emitter::Emitter;
use crate::location::{process_location, remote_launch_failure, RemoteEnv};
use crate::text::{clamp, TEXT_LIMIT};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PerTurnCli {
    Cursor,
    Agy,
}

impl PerTurnCli {
    fn as_str(self) -> &'static str {
        match self {
            PerTurnCli::Cursor => "cursor",
            PerTurnCli::Agy => "agy",
        }
    }
}

pub struct PerTurnBridge {
    pub cli: PerTurnCli,
    pub exe: Option<String>,
    pub cwd: String,
    pub model: Option<String>,
    pub out: Emitter,
    pub thread: Option<String>,
    /// Whether the session banner has been drawn. Cursor announces it again at
    /// the head of every turn, because for cursor every turn is a new process —
    /// which is exactly the thing this is hiding.
    opened: bool,
    environment_reported: bool,
    log_dir: Option<PathBuf>,
    log_path: Option<PathBuf>,
}

impl PerTurnBridge {
    pub fn new(cli: PerTurnCli, cwd: &str, model: Option<String>, out: Emitter, exe: Option<String>) -> Self {
        Self {
            cli,
            exe,
            cwd: cwd.to_string(),
            model,
            out,
            thread: None,
            opened: false,
            environment_reported: false,
            log_dir: None,
            log_path: None,
        }
    }

    pub fn start(&mut self) -> bool {
        self.out.emit(json!({
            "type": "system",
            "subtype": "init",
            "cwd": self.cwd,
            "model": self.model.clone().unwrap_or_default(),
            "tools": [],
        }));
        self.opened = true;
        true
    }

    /// Nothing is running between turns, so there is nothing to be dead.
    pub fn alive(&self) -> bool {
        true
    }

    fn argv(&mut self, text: &str) -> std::io::Result<Vec<String>> {
        match self.cli {
            PerTurnCli::Cursor => {
                let mut argv = vec![
                    self.exe.clone().unwrap_or_else(|| "cursor-agent".into()),
                    "-p".into(),
                    "--force".into(),
                    "--output-format".into(),
                    "stream-json".into(),
                ];
                if let Some(model) = self.model.as_deref() {
                    argv.push("--model".into());
                    argv.push(model.to_string());
                }
                if let Some(thread) = self.thread.as_deref() {
                    argv.push("--resume".into());
                    argv.push(thread.to_string());
                }
                argv.push(text.to_string());
                Ok(argv)
            }
            PerTurnCli::Agy => {
                self.ensure_agy_log()?;
                let mut argv = vec![
                    self.exe.clone().unwrap_or_else(|| "agy".into()),
                    "--dangerously-skip-permissions".into(),
                    "--log-file".into(),
                    self.log_path
                        .as_ref()
                        .map(|p| p.display().to_string())
                        .unwrap_or_default(),
                ];
                if let Some(thread) = self.thread.as_deref() {
                    // NOT `--continue`: that means "the most recent
                    // conversation" for the whole machine, so two agents here
                    // would steal each other's thread. The first turn starts
                    // fresh and pins the id afterwards.
                    argv.push("--conversation".into());
                    argv.push(thread.to_string());
                }
                // `--print` is a string flag: it swallows the next token as
                // the prompt, so `agy --print --dangerously-skip-permissions
                // "…"` asks agy to explain that flag. Everything else has to
                // come first.
                argv.push("--print".into());
                argv.push(text.to_string());
                Ok(argv)
            }
        }
    }

    pub fn turn(&mut self, text: &str, timeout: Option<Duration>) {
        self.out.sent(text);

        let argv = match self.argv(text) {
            Ok(argv) => argv,
            Err(e) => {
                self.out.result(
                    &format!("could not start {}: {e}", self.cli.as_str()),
                    "spawn_failed",
                    None,
                    true,
                );
                return;
            }
        };
        let located = match process_location(&RemoteEnv::from_process(), &argv, &self.cwd) {
            Ok(located) => located,
            Err(e) => {
                self.out.result(
                    &format!("could not start {}: {e}", self.cli.as_str()),
                    "spawn_failed",
                    None,
                    true,
                );
                return;
            }
        };

        let (program, rest) = match located.argv.split_first() {
            Some(pair) => pair,
            // `argv` always puts the CLI in first, and the remote form adds
            // ssh ahead of that, so there is no way to arrive here today. It
            // says so anyway: every other way out of this function reports
            // something, and a silent return is how a pane ends up waiting on
            // a turn that already gave up.
            None => {
                self.out.result(
                    &format!("could not start {}: no command to run", self.cli.as_str()),
                    "spawn_failed",
                    None,
                    true,
                );
                return;
            }
        };
        let mut command = Command::new(program);
        command
            .args(rest)
            .stdout(Stdio::piped())
            // Its own diagnostics are not part of the answer.
            .stderr(Stdio::null());
        if let Some(dir) = located.cwd.as_deref() {
            command.current_dir(dir);
        }
        command.env_remove("CLAUDECODE");
        command.env_remove("CLAUDE_CODE_ENTRYPOINT");

        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(e) => {
                self.out.result(
                    &format!("could not start {}: {e}", self.cli.as_str()),
                    "spawn_failed",
                    None,
                    true,
                );
                return;
            }
        };
        let stdout = child.stdout.take().expect("stdout is piped");

        // An opt-in watchdog rather than a reader thread: the answer is drawn as it
        // arrives, and drawing needs the emitter, which cannot be in two
        // places. Killing on the deadline turns the read into an EOF.
        //
        // It waits on a channel rather than sleeping, so a turn that finishes
        // early ends the thread with it. A plain sleep left one alive for the
        // rest of the opt-in timeout, accumulating one per turn, each holding
        // a pid it no longer owns. `kill(pid, 0)` succeeds
        // for whoever inherited that number, so a late sleeper could signal an
        // unrelated process.
        let killed = Arc::new(AtomicBool::new(false));
        let (finished, watchdog): (Option<_>, Option<_>) = timeout
            .map(|timeout| {
                let pid = child.id();
                let flag = Arc::clone(&killed);
                let (finished, wait_for_finish) = std::sync::mpsc::channel::<()>();
                let watchdog = std::thread::spawn(move || {
                    // Disconnected means the turn ended and the sender was dropped.
                    if wait_for_finish.recv_timeout(timeout)
                        != Err(std::sync::mpsc::RecvTimeoutError::Timeout)
                    {
                        return;
                    }
                    // SAFETY: signal 0 first — a pid that has been reaped and reused
                    // must not be signalled by mistake.
                    unsafe {
                        if libc::kill(pid as libc::pid_t, 0) == 0 {
                            flag.store(true, Ordering::SeqCst);
                            libc::kill(pid as libc::pid_t, libc::SIGTERM);
                        }
                    }
                });
                (finished, watchdog)
            })
            .unzip();

        let said = match self.cli {
            PerTurnCli::Cursor => {
                self.read_cursor(stdout);
                String::new()
            }
            PerTurnCli::Agy => self.read_agy(stdout),
        };
        let status = child.wait();
        drop(finished);
        if let Some(watchdog) = watchdog {
            let _ = watchdog.join();
        }

        if killed.load(Ordering::SeqCst) {
            self.out.result(
                &format!(
                    "{} did not finish in {}s",
                    self.cli.as_str(),
                    timeout.map_or(0.0, |value| value.as_secs_f64())
                ),
                "timeout",
                None,
                true,
            );
            return;
        }

        let code = status.ok().and_then(|s| s.code()).unwrap_or(-1);

        // Before the cursor branch, because the wrapper fails the same way for
        // both and neither writes a result of its own when it does. A remote
        // turn whose `.profile` or `agent-env` would not load exits 77/78 with
        // nothing on stdout, so returning here without saying so leaves the
        // pane waiting for a completion that is never coming.
        if let Some(failure) = remote_launch_failure(Some(code)) {
            self.out.result(failure, "environment_failed", None, true);
            return;
        }

        if self.cli == PerTurnCli::Cursor {
            // cursor reports its own turn; `read_cursor` passed its result
            // through already.
            return;
        }

        // Once pinned, kept: the log accumulates, and re-reading it every turn
        // would let a later line move a thread that was already decided.
        if self.thread.is_none() {
            self.thread = self.agy_thread();
        }

        // A turn that ends with nothing said is not a success — reporting it
        // as one is how an empty answer becomes a completed task. And a turn
        // with no result at all never ends, because whoever is watching for
        // completion is still waiting for this line.
        if code != 0 {
            let body = if said.is_empty() {
                format!("{} exited {code}", self.cli.as_str())
            } else {
                said
            };
            self.out
                .result(&body, &format!("exit_{code}"), None, true);
        } else if said.trim().is_empty() {
            self.out
                .result("the turn ended without an answer", "empty", None, true);
        } else {
            self.out.result(&said, "end_turn", None, false);
        }
    }

    /// Pass cursor's events through — they are already claude's shape.
    ///
    /// `system/init`, `user`, `assistant` with content blocks, `result` with
    /// `is_error` and `usage`: the only CLI here that needs no translation.
    /// What it needs instead is the per-turn process hidden — a fresh `init`
    /// every turn would redraw the session banner, and its echo of the prompt
    /// would read as a new question rather than the receipt for one.
    fn read_cursor(&mut self, stdout: std::process::ChildStdout) {
        let mut thinking = String::new();
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let line = line.trim();
            if !line.starts_with('{') {
                continue;
            }
            let Ok(obj) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            if crate::location::is_environment_diagnostic(&obj) {
                if !self.environment_reported {
                    self.out.emit(obj);
                    self.environment_reported = true;
                }
                continue;
            }
            if let Some(session) = obj.get("session_id").and_then(Value::as_str) {
                self.thread = Some(session.to_string());
            }
            match obj.get("type").and_then(Value::as_str) {
                Some("result") => {
                    self.cursor_result(obj);
                    continue;
                }
                Some("tool_call") => {
                    self.cursor_tool(&obj);
                    continue;
                }
                Some("system") => {
                    if self.opened {
                        continue;
                    }
                    self.opened = true;
                }
                // Already emitted as the receipt, with the sender known.
                Some("user") => continue,
                Some("thinking") => {
                    // Deltas, so they are joined and shown once rather than a
                    // rule per fragment.
                    if obj.get("subtype").and_then(Value::as_str) == Some("delta") {
                        thinking.push_str(obj.get("text").and_then(Value::as_str).unwrap_or(""));
                    } else if !thinking.is_empty() {
                        self.out.emit(json!({
                            "type": "assistant",
                            "message": {"content": [
                                {"type": "thinking", "thinking": thinking}]},
                        }));
                        thinking = String::new();
                    }
                    continue;
                }
                _ => {}
            }
            self.out.emit(obj);
        }
    }

    /// `{"<name>ToolCall": {"args": …, "result": {"success"|"error": …}}}`.
    ///
    /// The tool's name is the wrapper key, which is the one shape here that
    /// has to be read structurally rather than by field.
    fn cursor_tool(&mut self, obj: &Value) {
        let Some(call) = obj.get("tool_call").and_then(Value::as_object) else {
            return;
        };
        let Some(key) = call.keys().find(|k| k.ends_with("ToolCall")) else {
            return;
        };
        let body = call.get(key).cloned().unwrap_or(Value::Null);
        let name = key.trim_end_matches("ToolCall").to_string();

        if obj.get("subtype").and_then(Value::as_str) == Some("started") {
            let args = body.get("args").cloned().unwrap_or(Value::Null);
            let headline = ["command", "path", "pattern", "query"]
                .iter()
                .find_map(|k| args.get(*k).and_then(Value::as_str))
                .unwrap_or("")
                .to_string();
            self.out.tool_command(&name, &headline, "");
            return;
        }

        let result = body.get("result").cloned().unwrap_or(Value::Null);
        let failed = result.get("error").is_some();
        let payload = if failed {
            result.get("error")
        } else {
            result.get("success")
        };
        let text = match payload {
            Some(Value::Object(map)) => map
                .get("content")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| {
                    serde_json::to_string(&Value::Object(map.clone())).unwrap_or_default()
                }),
            Some(Value::String(s)) => s.clone(),
            Some(other) => other.to_string(),
            None => String::new(),
        };
        self.out.tool_result(&clamp(&text, TEXT_LIMIT), failed, "");
    }

    /// Cursor's own verdict, with one correction.
    ///
    /// Measured: asked to recall a word, cursor worked it out in its reasoning
    /// — "The word is TANGERINE" — emitted no assistant text, and ended the
    /// turn `is_error: false` with `result: ""`. Passed through, that is a
    /// completed task with no answer in it. The turn did end, so it must not
    /// sit open; but nothing was said, so it cannot be called a success. The
    /// reasoning is not promoted into the answer — inventing one from what the
    /// model was thinking is worse than saying nothing was said.
    fn cursor_result(&mut self, obj: Value) {
        let said = obj
            .get("result")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        let errored = obj
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if said.is_empty() && !errored {
            let mut corrected = obj;
            corrected["is_error"] = Value::Bool(true);
            corrected["subtype"] = Value::String("error".into());
            corrected["stop_reason"] = Value::String("empty".into());
            corrected["result"] =
                Value::String("the turn ended with an answer only in its reasoning".into());
            self.out.emit(corrected);
            return;
        }
        self.out.emit(obj);
    }

    /// agy answers in plain text, so the whole answer is one block.
    ///
    /// Emitting each line as it arrives would draw a rule per line; there is
    /// no structure here to tell a paragraph from a tool's output.
    fn read_agy(&mut self, stdout: std::process::ChildStdout) -> String {
        let mut lines: Vec<String> = Vec::new();
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if let Ok(obj) = serde_json::from_str::<Value>(&line) {
                if crate::location::is_environment_diagnostic(&obj) {
                    if !self.environment_reported {
                        self.out.emit(obj);
                        self.environment_reported = true;
                    }
                    continue;
                }
            }
            // Its argument parser complains on stdout before answering.
            if line.starts_with("# Un-recognized argument") {
                continue;
            }
            lines.push(line);
        }
        let said = lines.join("\n").trim().to_string();
        self.out.text(&said);
        said
    }

    /// agy's own words, from the server log it is told to write.
    fn agy_thread(&self) -> Option<String> {
        let path = self.log_path.as_ref()?;
        let text = read_private_file(path)?;
        agy_conversation_id(&text)
    }

    fn ensure_agy_log(&mut self) -> std::io::Result<()> {
        if self.log_path.is_some() {
            return Ok(());
        }
        let directory = tempfile::Builder::new()
            .prefix(&format!("term-mesh-agy-{}-", unsafe { libc::getuid() }))
            .tempdir()?
            .keep();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;

        let path = directory.join("conversation.log");
        let file = std::fs::File::create(&path)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        drop(file);

        self.log_dir = Some(directory);
        self.log_path = Some(path);
        Ok(())
    }

    pub fn stop(&mut self) {
        if let Some(path) = self.log_path.take() {
            let _ = std::fs::remove_file(path);
        }
        if let Some(dir) = self.log_dir.take() {
            let _ = std::fs::remove_dir(dir);
        }
    }
}

/// The agy log is kept past the tempdir guard on purpose — the id is read back
/// out of it between turns — so something has to remove it at the end. Doing it
/// here rather than asking the exit path to remember: a bridge can end by
/// closed input, by a killed process, or by main simply returning, and only one
/// of those is a place to put a call.
impl Drop for PerTurnBridge {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Read a file only if it is a plain file this user owns and nobody else can
/// touch, following no symlink to get there.
///
/// The conversation id is read back out of a path this process handed to
/// another program, so the checks are the point: a symlink swapped in, a file
/// that became someone else's, or one left group-writable all mean the id
/// under it is not necessarily ours.
fn read_private_file(path: &std::path::Path) -> Option<String> {
    use std::os::unix::ffi::OsStrExt;
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: a C string built from the path, and O_NOFOLLOW refuses a
    // symlink outright rather than resolving it.
    let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_RDONLY | libc::O_NOFOLLOW) };
    if fd < 0 {
        return None;
    }
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: fd is open and stat is owned local storage.
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        unsafe { libc::close(fd) };
        return None;
    }
    let is_regular = stat.st_mode & libc::S_IFMT == libc::S_IFREG;
    let ours = stat.st_uid == unsafe { libc::getuid() };
    let private = stat.st_mode & 0o077 == 0;
    if !is_regular || !ours || !private {
        unsafe { libc::close(fd) };
        return None;
    }
    use std::io::Read;
    use std::os::unix::io::FromRawFd;
    // SAFETY: ownership of fd moves into the File, which closes it.
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut text = String::new();
    file.read_to_string(&mut text).ok()?;
    Some(text)
}

/// The last `Created conversation <uuid>` agy logged.
fn agy_conversation_id(text: &str) -> Option<String> {
    const MARKER: &str = "Created conversation ";
    let mut found = None;
    let mut rest = text;
    while let Some(at) = rest.find(MARKER) {
        let after = &rest[at + MARKER.len()..];
        let id: String = after.chars().take(36).collect();
        if id.len() == 36
            && id
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase() || c == '-')
        {
            found = Some(id);
        }
        rest = &rest[at + MARKER.len()..];
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emitter::testing::{blocks, captured};
    use std::sync::{Arc, Mutex};

    fn bridge(cli: PerTurnCli) -> (PerTurnBridge, Arc<Mutex<Vec<Value>>>) {
        let (out, sink) = captured();
        (PerTurnBridge::new(cli, "/tmp/project", None, out, None), sink)
    }

    fn last_result(sink: &Arc<Mutex<Vec<Value>>>) -> Value {
        sink.lock()
            .unwrap()
            .iter()
            .filter(|e| e["type"] == "result")
            .next_back()
            .cloned()
            .expect("a result")
    }

    #[test]
    fn cursor_resumes_its_own_thread_and_agy_never_says_continue() {
        let (mut cursor, _) = bridge(PerTurnCli::Cursor);
        cursor.thread = Some("thread-7".into());
        let argv = cursor.argv("do it").unwrap();
        assert!(argv.windows(2).any(|w| w == ["--resume", "thread-7"]));
        assert_eq!(argv.last().unwrap(), "do it");

        let (mut agy, _) = bridge(PerTurnCli::Agy);
        let argv = agy.argv("do it").unwrap();
        // `--continue` would mean the most recent conversation on the whole
        // machine, so two agents would steal each other's thread.
        assert!(!argv.iter().any(|a| a == "--continue"));
        // `--print` swallows the next token, so nothing may follow the prompt.
        let print_at = argv.iter().position(|a| a == "--print").unwrap();
        assert_eq!(argv[print_at + 1], "do it");
        assert_eq!(print_at + 2, argv.len());
        agy.stop();
    }

    #[test]
    fn an_empty_cursor_answer_is_not_a_success() {
        let (mut b, sink) = bridge(PerTurnCli::Cursor);

        b.cursor_result(json!({"type": "result", "is_error": false, "result": "  "}));

        let result = last_result(&sink);
        assert_eq!(result["is_error"], true);
        assert_eq!(result["stop_reason"], "empty");
        assert!(result["result"]
            .as_str()
            .unwrap()
            .contains("only in its reasoning"));
    }

    #[test]
    fn a_real_cursor_answer_passes_through_untouched() {
        let (mut b, sink) = bridge(PerTurnCli::Cursor);

        b.cursor_result(json!({"type": "result", "is_error": false, "result": "TANGERINE"}));

        let result = last_result(&sink);
        assert_eq!(result["is_error"], false);
        assert_eq!(result["result"], "TANGERINE");
    }

    #[test]
    fn a_cursor_tool_is_named_by_its_wrapper_key() {
        let (mut b, sink) = bridge(PerTurnCli::Cursor);

        b.cursor_tool(&json!({"type": "tool_call", "subtype": "started",
                              "tool_call": {"shellToolCall": {"args": {"command": "ls -l"}}}}));

        let call = &blocks(&sink, "tool_use")[0];
        assert_eq!(call["name"], "shell");
        assert_eq!(call["input"]["command"], "ls -l");
    }

    #[test]
    fn a_failed_cursor_tool_reports_its_error_body() {
        let (mut b, sink) = bridge(PerTurnCli::Cursor);

        b.cursor_tool(&json!({"type": "tool_call", "subtype": "completed",
                              "tool_call": {"readToolCall": {
                                  "result": {"error": {"content": "no such file"}}}}}));

        let result = &blocks(&sink, "tool_result")[0];
        assert_eq!(result["content"], "no such file");
        assert_eq!(result["is_error"], true);
    }

    #[test]
    fn agys_conversation_id_is_the_last_one_it_logged() {
        let text = "\
Created conversation 11111111-1111-4111-8111-111111111111\n\
noise\n\
Created conversation 22222222-2222-4222-8222-222222222222\n";

        assert_eq!(
            agy_conversation_id(text).as_deref(),
            Some("22222222-2222-4222-8222-222222222222")
        );
        assert_eq!(agy_conversation_id("nothing here"), None);
        assert_eq!(agy_conversation_id("Created conversation short"), None);
    }

    #[test]
    fn a_log_that_is_not_ours_alone_is_not_read() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("conversation.log");
        std::fs::write(&path, "Created conversation 33333333-3333-4333-8333-333333333333").unwrap();
        // As `ensure_agy_log` creates it — the default here is whatever umask
        // says, which on a normal account is already group-readable.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();

        assert!(read_private_file(&path).is_some());

        // Group-readable is enough to disqualify it: the id under it is no
        // longer necessarily the one this bridge asked for.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_private_file(&path).is_none());

        let link = dir.path().join("link.log");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(read_private_file(&link).is_none(), "O_NOFOLLOW refuses a symlink");
    }

    #[test]
    fn a_per_turn_bridge_is_always_alive_between_turns() {
        let (b, _) = bridge(PerTurnCli::Cursor);
        assert!(b.alive());
    }

    /// A stand-in for the CLI: it ignores every argument and exits how the
    /// test says.
    fn fake_cli(dir: &std::path::Path, body: &str) -> String {
        let path = dir.join("fake-cli");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path.display().to_string()
    }

    fn bridge_with(cli: PerTurnCli, exe: String) -> (PerTurnBridge, Arc<Mutex<Vec<Value>>>) {
        let (out, sink) = captured();
        (
            PerTurnBridge::new(cli, "/tmp", None, out, Some(exe)),
            sink,
        )
    }

    #[test]
    fn a_turn_that_finishes_early_does_not_leave_its_watchdog_behind() {
        let dir = tempfile::tempdir().unwrap();
        let (mut b, _) = bridge_with(PerTurnCli::Agy, fake_cli(dir.path(), "echo done"));

        // A generous deadline the turn will not need. Before the watchdog
        // could be cancelled it slept the whole of this, one thread per turn,
        // each still holding a pid it no longer owned.
        let started = std::time::Instant::now();
        b.turn("hi", Some(Duration::from_secs(30)));

        assert!(
            started.elapsed() < Duration::from_secs(2),
            "the watchdog has to end with the turn, not outlive it"
        );
    }

    #[test]
    fn a_turn_without_a_deadline_finishes_normally() {
        let dir = tempfile::tempdir().unwrap();
        let (mut b, sink) = bridge_with(PerTurnCli::Agy, fake_cli(dir.path(), "echo done"));

        b.turn("hi", None);

        let result = last_result(&sink);
        assert_eq!(result["stop_reason"], "end_turn");
        assert_eq!(result["result"], "done");
    }

    #[test]
    fn agy_environment_diagnostic_is_not_part_of_the_answer() {
        let dir = tempfile::tempdir().unwrap();
        let body = r#"echo '{"type":"system","subtype":"environment","shell":"zsh","profile_fallback":"loaded","agent_env":"loaded","present_keys":[]}'
echo done"#;
        let (mut b, sink) = bridge_with(PerTurnCli::Agy, fake_cli(dir.path(), body));

        b.turn("hi", Some(Duration::from_secs(10)));

        let events = sink.lock().unwrap();
        assert_eq!(events.iter().filter(|e| e["subtype"] == "environment").count(), 1);
        let result = events.iter().find(|e| e["type"] == "result").unwrap();
        assert_eq!(result["result"], "done");
    }

    #[test]
    fn a_remote_wrapper_failure_is_reported_for_both_clis() {
        // 77 and 78 mean the remote shell could not load ~/.profile or
        // agent-env. Neither CLI writes anything on stdout when that happens,
        // so a bridge that stays quiet leaves the pane waiting forever.
        for (cli, code, expected) in [
            (PerTurnCli::Cursor, 77, "~/.profile"),
            (PerTurnCli::Agy, 78, "agent-env"),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let (mut b, sink) = bridge_with(cli, fake_cli(dir.path(), &format!("exit {code}")));

            b.turn("hi", Some(Duration::from_secs(10)));

            let result = last_result(&sink);
            assert_eq!(result["stop_reason"], "environment_failed", "{cli:?}");
            assert!(
                result["result"].as_str().unwrap().contains(expected),
                "{cli:?}: {}",
                result["result"]
            );
        }
    }

    #[test]
    fn the_agy_log_is_removed_when_the_bridge_goes_away() {
        let dir = tempfile::tempdir().unwrap();
        let (mut b, _) = bridge_with(PerTurnCli::Agy, fake_cli(dir.path(), "echo hi"));
        b.turn("hi", Some(Duration::from_secs(10)));

        let log = b.log_path.clone().expect("agy was given a log to write");
        assert!(log.exists());

        // The tempdir guard is deliberately released so the id survives
        // between turns, which makes dropping the bridge the only cleanup.
        drop(b);
        assert!(!log.exists(), "every agy session would otherwise leave one behind");
    }
}
