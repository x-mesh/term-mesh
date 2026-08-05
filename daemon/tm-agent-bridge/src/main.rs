//! Speak an agent CLI's protocol on its behalf, and normalise what comes back.
//!
//! The Rust port of `scripts/spike/tm-agent-bridge.py`, which is still what
//! the app runs. Why a bridge at all — the three CLI shapes it reconciles:
//!
//! * **claude** needs none of this. Its channel is one-directional: write a
//!   line of NDJSON to stdin and that is the whole delivery. It never reaches
//!   here.
//! * **codex, kiro, gemini** are request/response. `thread/start` hands back an
//!   id that every later `turn/start` must carry, so whoever delivers a turn
//!   has to be reading the replies — which a one-way pipe cannot do. Something
//!   has to own both ends of the child's stdio.
//! * **cursor, agy** have no stdin channel at all. A turn *is* a process, and
//!   the thread is carried by an id handed back afterwards.
//!
//! It is also the one place the vocabularies meet. Each CLI ends a turn
//! differently, and an app that learns all of them learns them everywhere, so
//! the bridge emits claude's shape for every CLI and everything upstream stays
//! single-vocabulary.
//!
//! The CLI surface is deliberately identical to the Python bridge's: the two
//! are meant to be swappable behind one launch line while the port is proven.

mod acp;
mod codex;
mod emitter;
mod jsonrpc;
mod location;
mod per_turn;
mod text;
mod transport;

use std::io::Read;
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use clap::Parser;
use serde_json::Value;

use acp::AcpBridge;
use codex::CodexBridge;
use emitter::Emitter;
use per_turn::{PerTurnBridge, PerTurnCli};
use text::{split_input_frames, MAX_FRAME_BYTES};
use transport::{ProcessChild, Transport};

/// The CLIs a bridge can drive.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
enum Cli {
    Codex,
    Kiro,
    Gemini,
    Cursor,
    Agy,
}

impl Cli {
    fn as_str(self) -> &'static str {
        match self {
            Cli::Codex => "codex",
            Cli::Kiro => "kiro",
            Cli::Gemini => "gemini",
            Cli::Cursor => "cursor",
            Cli::Agy => "agy",
        }
    }
}

#[derive(Parser, Debug)]
#[command(name = "tm-agent-bridge", about, version)]
struct Args {
    /// Which CLI's protocol to speak.
    #[arg(long, value_enum)]
    cli: Cli,

    /// Turns arrive here; omit to read them from stdin.
    ///
    /// A FIFO when a terminal hosts this and the writer is another process;
    /// plain stdin when the app hosts it directly.
    #[arg(long)]
    fifo: Option<String>,

    /// Normalised events are appended here too.
    #[arg(long)]
    events: Option<String>,

    #[arg(long)]
    cwd: Option<String>,

    #[arg(long)]
    model: Option<String>,

    /// Path to the CLI binary.
    ///
    /// The app resolves a CLI's path from Settings; without this the bridge
    /// would find a different binary on PATH than the one the user chose.
    #[arg(long)]
    exe: Option<String>,

    #[arg(long = "turn-timeout", default_value_t = 600.0)]
    turn_timeout: f64,
}

/// Colour only for a terminal. When the app hosts this there is nothing to
/// interpret the escapes, and they would arrive as literal garbage in a view
/// that draws text rather than cells.
pub fn log(message: &str) {
    use std::io::IsTerminal;
    if std::io::stdout().is_terminal() {
        println!("\x1b[38;5;244m[bridge] {message}\x1b[0m");
    } else {
        println!("[bridge] {message}");
    }
}

/// What every protocol bridge has to offer the loop that drives it.
trait Bridge {
    fn start(&mut self) -> bool;
    fn turn(&mut self, text: &str, timeout: Duration);
    fn alive(&self) -> bool;
    /// Why the session ended, if the transport knows.
    fn failure(&self) -> Option<String>;
    /// The child's own account, for when the transport has none.
    fn child_failure_message(&self) -> String;
}

impl<T: Transport> Bridge for CodexBridge<T> {
    fn start(&mut self) -> bool {
        CodexBridge::start(self)
    }
    fn turn(&mut self, text: &str, timeout: Duration) {
        CodexBridge::turn(self, text, timeout)
    }
    fn alive(&self) -> bool {
        self.rpc.child.alive()
    }
    fn failure(&self) -> Option<String> {
        self.rpc.failure.clone()
    }
    fn child_failure_message(&self) -> String {
        self.rpc.child.failure_message()
    }
}

impl Bridge for PerTurnBridge {
    fn start(&mut self) -> bool {
        PerTurnBridge::start(self)
    }
    fn turn(&mut self, text: &str, timeout: Duration) {
        PerTurnBridge::turn(self, text, timeout)
    }
    fn alive(&self) -> bool {
        // Cursor and agy use a fresh child for every turn, so the bridge that
        // waits between them is never the thing that died.
        PerTurnBridge::alive(self)
    }
    fn failure(&self) -> Option<String> {
        None
    }
    fn child_failure_message(&self) -> String {
        "agent process exited".to_string()
    }
}

impl<T: Transport> Bridge for AcpBridge<T> {
    fn start(&mut self) -> bool {
        AcpBridge::start(self)
    }
    fn turn(&mut self, text: &str, timeout: Duration) {
        AcpBridge::turn(self, text, timeout)
    }
    fn alive(&self) -> bool {
        self.rpc.child.alive()
    }
    fn failure(&self) -> Option<String> {
        self.rpc.failure.clone()
    }
    fn child_failure_message(&self) -> String {
        self.rpc.child.failure_message()
    }
}

/// What wakes the loop. Turns and the child going away arrive on one channel,
/// so an idle pane costs no timer.
enum Wake {
    Input(Vec<u8>),
    InputClosed,
    ChildGone,
}

/// The text of a turn, however it was written.
///
/// Turns arrive in claude's envelope whoever wrote them, so the caller never
/// has to know which CLI is behind this. A line that is not JSON is taken as
/// the instruction itself.
fn turn_text(line: &str) -> String {
    let line = line.trim();
    if line.is_empty() {
        return String::new();
    }
    let Ok(obj) = serde_json::from_str::<Value>(line) else {
        return line.to_string();
    };
    match obj.get("message").and_then(|m| m.get("content")) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect(),
        _ => String::new(),
    }
}

fn main() -> std::process::ExitCode {
    let args = Args::parse();
    let cwd = args
        .cwd
        .clone()
        .or_else(|| std::env::current_dir().ok().map(|p| p.display().to_string()))
        .unwrap_or_else(|| ".".to_string());

    let mut out = match Emitter::new(args.events.as_deref()) {
        Ok(out) => out,
        Err(e) => {
            eprintln!("tm-agent-bridge: cannot open events file: {e}");
            return std::process::ExitCode::FAILURE;
        }
    };

    // A persistent CLI is spawned once and spoken to; a per-turn CLI has
    // nothing running between turns, so there is no child here to watch.
    let persistent_argv: Option<Vec<String>> = match args.cli {
        Cli::Codex => Some(vec![
            args.exe.clone().unwrap_or_else(|| "codex".into()),
            "app-server".into(),
        ]),
        // `kiro-cli acp`, NOT `kiro-cli chat acp`: both parse and only the
        // first is a server. The second starts the interactive chat agent,
        // which reads the handshake as a user message and answers it in prose.
        Cli::Kiro => Some(vec![
            args.exe.clone().unwrap_or_else(|| "kiro-cli".into()),
            "acp".into(),
            "--trust-all-tools".into(),
        ]),
        Cli::Gemini => Some(vec![
            args.exe.clone().unwrap_or_else(|| "gemini".into()),
            "--acp".into(),
            "--yolo".into(),
        ]),
        Cli::Cursor | Cli::Agy => None,
    };

    let (mut bridge, exit_rx): (Box<dyn Bridge>, Option<Receiver<()>>) = match persistent_argv {
        Some(argv) => {
            let (child, exit_rx) = match ProcessChild::spawn(&argv, &cwd) {
                Ok(pair) => pair,
                Err(e) => {
                    out.result(&format!("{e}"), "startup_failed", None, true);
                    return std::process::ExitCode::FAILURE;
                }
            };
            let bridge: Box<dyn Bridge> = match args.cli {
                Cli::Codex => Box::new(CodexBridge::new(child, out, &cwd, args.model.clone())),
                _ => Box::new(AcpBridge::new(child, out, &cwd, args.model.clone())),
            };
            (bridge, Some(exit_rx))
        }
        None => {
            let cli = if args.cli == Cli::Cursor {
                PerTurnCli::Cursor
            } else {
                PerTurnCli::Agy
            };
            (
                Box::new(PerTurnBridge::new(
                    cli,
                    &cwd,
                    args.model.clone(),
                    out,
                    args.exe.clone(),
                )),
                None,
            )
        }
    };

    if !bridge.start() {
        // The emitter moved into the bridge, so the failure is reported
        // through a fresh one on the same streams.
        let mut out = Emitter::new(args.events.as_deref()).unwrap_or_else(|_| {
            Emitter::new(None).expect("stdout is always available")
        });
        let failure = bridge.failure();
        let stop = if failure.is_some() {
            "environment_failed"
        } else {
            "startup_failed"
        };
        out.result(&failure.unwrap_or_default(), stop, None, true);
        return std::process::ExitCode::FAILURE;
    }
    log(&format!(
        "{} ready — turns on {}",
        args.cli.as_str(),
        args.fifo.as_deref().unwrap_or("stdin")
    ));

    let (wake_tx, wake_rx) = mpsc::channel();
    spawn_input_reader(args.fifo.clone(), wake_tx.clone());
    match exit_rx {
        Some(exit_rx) => spawn_exit_watcher(exit_rx, wake_tx),
        // Nothing runs between turns, so nothing can be waited on for its
        // exit. Dropping the sender keeps the loop's recv honest.
        None => drop(wake_tx),
    }

    let code = consume(
        &mut *bridge,
        wake_rx,
        Duration::from_secs_f64(args.turn_timeout),
        args.events.as_deref(),
    );
    std::process::ExitCode::from(code)
}

fn spawn_input_reader(fifo: Option<String>, wake: mpsc::Sender<Wake>) {
    std::thread::spawn(move || {
        let mut source: Box<dyn Read> = match fifo.as_deref() {
            // Holding both ends avoids EOF spinning when an external writer
            // closes and reopens.
            Some(path) => match std::fs::OpenOptions::new().read(true).write(true).open(path) {
                Ok(file) => Box::new(file),
                Err(e) => {
                    log(&format!("cannot open fifo: {e}"));
                    let _ = wake.send(Wake::InputClosed);
                    return;
                }
            },
            None => Box::new(std::io::stdin()),
        };
        let mut buffer = [0u8; 65536];
        loop {
            match source.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    if wake.send(Wake::Input(buffer[..n].to_vec())).is_err() {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = wake.send(Wake::InputClosed);
    });
}

fn spawn_exit_watcher(exit_rx: Receiver<()>, wake: mpsc::Sender<Wake>) {
    std::thread::spawn(move || {
        if exit_rx.recv().is_ok() {
            let _ = wake.send(Wake::ChildGone);
        }
    });
}

/// Read turns and child-exit events, without polling while idle.
fn consume(
    bridge: &mut dyn Bridge,
    wake: Receiver<Wake>,
    turn_timeout: Duration,
    events: Option<&str>,
) -> u8 {
    let mut pending: Vec<u8> = Vec::new();
    let mut out = Emitter::new(events).unwrap_or_else(|_| {
        Emitter::new(None).expect("stdout is always available")
    });

    let exit_failure = |bridge: &dyn Bridge| -> String {
        bridge
            .failure()
            .unwrap_or_else(|| bridge.child_failure_message())
    };

    while let Ok(event) = wake.recv() {
        match event {
            Wake::ChildGone => {
                let failure = exit_failure(bridge);
                out.result(&failure, "process_exited", None, true);
                log(&failure);
                return 1;
            }
            Wake::InputClosed => {
                if !pending.iter().all(u8::is_ascii_whitespace) {
                    let line = String::from_utf8_lossy(&pending).into_owned();
                    let reported = take(bridge, &line, turn_timeout);
                    if !bridge.alive() {
                        if !reported {
                            out.result(&exit_failure(bridge), "process_exited", None, true);
                        }
                        return 1;
                    }
                }
                return 0;
            }
            Wake::Input(chunk) => {
                let split = split_input_frames(&mut pending, &chunk);
                pending = split.remainder;
                for raw in split.frames {
                    let reported = take(bridge, &raw, turn_timeout);
                    if !bridge.alive() {
                        if !reported {
                            out.result(&exit_failure(bridge), "process_exited", None, true);
                        }
                        log(&exit_failure(bridge));
                        return 1;
                    }
                }
                if let Some(size) = split.oversize {
                    // Refuse a writer that blew past the frame cap, and say so.
                    let message = format!(
                        "input frame exceeded {MAX_FRAME_BYTES} bytes ({size}); \
                         closing the transport"
                    );
                    out.result(&message, "input_too_large", None, true);
                    log(&message);
                    return 1;
                }
            }
        }
    }
    0
}

/// Run one turn. Returns whether the bridge already reported a failure, so
/// the caller does not report it twice.
fn take(bridge: &mut dyn Bridge, line: &str, timeout: Duration) -> bool {
    let text = turn_text(line);
    if text.is_empty() {
        return false;
    }
    bridge.turn(&text, timeout);
    bridge.failure().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_turn_is_read_out_of_claudes_envelope() {
        assert_eq!(
            turn_text(&json!({"message": {"content": "do the thing"}}).to_string()),
            "do the thing"
        );
        assert_eq!(
            turn_text(
                &json!({"message": {"content": [{"type": "text", "text": "one "},
                                                {"type": "text", "text": "two"}]}})
                .to_string()
            ),
            "one two"
        );
    }

    #[test]
    fn a_line_that_is_not_json_is_the_instruction_itself() {
        assert_eq!(turn_text("just do it"), "just do it");
        assert_eq!(turn_text("  "), "");
    }

    #[test]
    fn an_envelope_with_no_content_asks_for_nothing() {
        assert_eq!(turn_text(&json!({"message": {}}).to_string()), "");
        assert_eq!(turn_text(&json!({"other": 1}).to_string()), "");
    }
}
