//! Speak an agent CLI's protocol on its behalf, and normalise what comes back.
//!
//! The Rust port of `scripts/spike/tm-agent-bridge.py`, which is still the
//! implementation the app runs. This crate exists first so the packaging is
//! proven before any protocol code depends on it: a binary that is built but
//! never copied into the bundle fails only on other people's machines.
//!
//! Why a bridge at all — the three CLI shapes it reconciles:
//!
//! * **claude** needs none of this. Its channel is one-directional: write a
//!   line of NDJSON to stdin and that is the whole delivery. It never reaches
//!   here.
//! * **codex, kiro** are request/response. `thread/start` hands back an id that
//!   every later `turn/start` must carry, so whoever delivers a turn has to be
//!   reading the replies — which a one-way pipe cannot do. Something has to own
//!   both ends of the child's stdio.
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

mod codex;
mod emitter;
mod jsonrpc;
mod location;
mod text;
mod transport;

use clap::Parser;

/// The CLIs a bridge can drive. `gemini` is accepted for parity with the
/// Python bridge's argument surface.
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

fn main() -> std::process::ExitCode {
    let args = Args::parse();

    // Protocol support lands per CLI in the next step, each alongside the
    // tests ported from the Python bridge. Refusing loudly keeps a
    // half-finished binary from being mistaken for a working one — the
    // silent-success shape this bridge exists to prevent.
    eprintln!(
        "tm-agent-bridge: the {} protocol is not implemented in the Rust bridge yet; \
         the app still runs scripts/spike/tm-agent-bridge.py",
        args.cli.as_str()
    );
    // Plain failure on purpose: 77 and 78 already mean "a profile failed to
    // load" and "agent-env failed to load" to the remote launch path, and
    // reusing one here would report the wrong cause.
    std::process::ExitCode::FAILURE
}
