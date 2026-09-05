//! What a restart of the peer host actually costs.
//!
//! Issue #403: teardown stopped somewhere past `agent sessions terminated`, so
//! `systemd` held the unit until `TimeoutStopSec` and the relay socket was gone
//! for 90 seconds. The per-step limits and the off-runtime watchdog that answer
//! that are only worth what they do when a step stops returning, so these tests
//! inject each hang shape and measure the gap the client would see.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The daemon's own teardown budget (`SHUTDOWN_BUDGET` in `main.rs`).
const SHUTDOWN_BUDGET: Duration = Duration::from_secs(30);
/// The agent-session step's limit (`AGENT_LIMIT` in `main.rs`).
const AGENT_LIMIT: Duration = Duration::from_secs(12);
/// What one restart may cost. A clean teardown takes well under a second; this
/// leaves room for a loaded host without ever approaching the stop timeout.
const RESTART_BUDGET: Duration = Duration::from_secs(15);
/// How long a start may take before the test gives up on the socket.
const START_BUDGET: Duration = Duration::from_secs(30);
/// Slack over a bound, for process spawn and scheduling on a busy host.
const SLACK: Duration = Duration::from_secs(8);

struct Host {
    _home: tempfile::TempDir,
    root: PathBuf,
}

impl Host {
    fn new() -> Self {
        let home = tempfile::tempdir().expect("temp home");
        let root = home.path().to_path_buf();
        Self { _home: home, root }
    }

    fn peer_socket(&self) -> PathBuf {
        self.root.join("tm-peer.sock")
    }

    fn control_socket(&self) -> PathBuf {
        self.root.join("term-meshd.sock")
    }

    /// Start a daemon that shares nothing with the developer's own.
    ///
    /// The environment is cleared rather than extended: these tests run inside
    /// a term-mesh pane, which exports the production socket paths, and an
    /// inherited one would point this daemon at the running installation.
    fn start(&self, stall: Option<&str>, log: &str) -> Daemon {
        let log_path = self.root.join(log);
        // `tracing_subscriber::fmt()` writes to stdout; keep stderr with it so a
        // panic on the way down lands in the same journal.
        let journal = std::fs::File::create(&log_path).expect("daemon log");
        let journal_errors = journal.try_clone().expect("daemon log handle");
        let mut command = Command::new(env!("CARGO_BIN_EXE_term-meshd"));
        command
            .env_clear()
            .env("HOME", &self.root)
            .env("PATH", std::env::var("PATH").unwrap_or_default())
            .env("TERMMESH_DAEMON_UNIX_PATH", self.control_socket())
            .env("TERMMESH_PEER_SOCKET", self.peer_socket())
            .env("TERM_MESH_HTTP_DISABLED", "1")
            .env("RUST_LOG", "term_meshd=info")
            .stdin(Stdio::null())
            .stdout(Stdio::from(journal))
            .stderr(Stdio::from(journal_errors));
        if let Some(shape) = stall {
            command.env("TERMMESH_SHUTDOWN_STALL", shape);
        }
        let child = command.spawn().expect("term-meshd did not start");
        Daemon { child: Some(child), log: log_path }
    }

    /// Block until the relay socket accepts a connection, as a client retrying
    /// `Connection refused` would. This is the gap the issue measures.
    fn await_relay(&self) {
        let deadline = Instant::now() + START_BUDGET;
        let socket = self.peer_socket();
        while Instant::now() < deadline {
            if UnixStream::connect(&socket).is_ok() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("the relay socket did not accept a connection within {START_BUDGET:?}");
    }

    /// Block until both required servers have published their started
    /// receipts, which is what the daemon itself checks before it may
    /// terminate shared processes.
    ///
    /// Stopping before either receipt is read as a required server failing
    /// during startup, and teardown then skips the agent steps on purpose —
    /// which measures that path instead of a restart. A connect proves neither
    /// receipt: both listeners bind before the startup work that follows, so
    /// the kernel accepts into the backlog while the daemon still counts the
    /// server unstarted. The control server publishes its receipt just before
    /// its accept loop, so a reply is the proof; the peer server publishes its
    /// own immediately after the line it logs, so that line is the proof.
    fn await_ready(&self, daemon: &Daemon) {
        let deadline = Instant::now() + START_BUDGET;
        while Instant::now() < deadline {
            if daemon.journal().contains("peer-federation listening on") && self.answers_ping() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("both servers did not report started within {START_BUDGET:?}");
    }

    fn answers_ping(&self) -> bool {
        let Ok(stream) = UnixStream::connect(self.control_socket()) else {
            return false;
        };
        if stream
            .set_read_timeout(Some(Duration::from_millis(500)))
            .is_err()
        {
            return false;
        }
        let Ok(mut writer) = stream.try_clone() else {
            return false;
        };
        if writer.write_all(b"{\"id\":1,\"method\":\"ping\"}\n").is_err() {
            return false;
        }
        let mut reply = String::new();
        BufReader::new(stream).read_line(&mut reply).is_ok() && reply.contains("pong")
    }
}

struct Daemon {
    child: Option<Child>,
    log: PathBuf,
}

impl Daemon {
    fn pid(&self) -> i32 {
        self.child.as_ref().expect("daemon is running").id() as i32
    }

    /// Ask for a stop the way `systemd` does, and report how long the process
    /// took to go away.
    fn stop(&mut self) -> (Duration, Option<i32>) {
        let began = Instant::now();
        // SAFETY: signalling a pid this test spawned and still owns.
        unsafe { libc::kill(self.pid(), libc::SIGTERM) };
        let mut child = self.child.take().expect("daemon is running");
        let status = child.wait().expect("waiting on term-meshd");
        (began.elapsed(), status.code())
    }

    fn journal(&self) -> String {
        let mut body = String::new();
        if let Ok(mut file) = std::fs::File::open(&self.log) {
            let _ = file.read_to_string(&mut body);
        }
        body
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // A failed assertion must not leave a daemon behind.
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[test]
fn a_restart_costs_seconds_not_the_stop_timeout() {
    let host = Host::new();
    let mut daemon = host.start(None, "start.log");

    for round in 1..=3 {
        host.await_ready(&daemon);
        let began = Instant::now();
        let (teardown, code) = daemon.stop();
        daemon = host.start(None, &format!("restart-{round}.log"));
        host.await_relay();
        let unavailable = began.elapsed();

        assert_eq!(code, Some(0), "round {round} did not stop cleanly");
        assert!(
            unavailable < RESTART_BUDGET,
            "round {round}: the relay was unavailable for {unavailable:?} \
             (teardown {teardown:?}), over the {RESTART_BUDGET:?} bound"
        );
    }
}

#[test]
fn a_stalled_step_ends_at_its_own_limit_and_teardown_continues() {
    let host = Host::new();
    let mut daemon = host.start(Some("agents"), "stalled-step.log");
    host.await_ready(&daemon);

    let (teardown, code) = daemon.stop();

    let journal = daemon.journal();
    assert_eq!(code, Some(0), "a stalled step must not fail the stop");
    assert!(
        teardown >= AGENT_LIMIT,
        "teardown finished in {teardown:?}, too fast for the injected stall to have applied:\n{journal}"
    );
    assert!(
        teardown < AGENT_LIMIT + SLACK,
        "teardown took {teardown:?}; the stalled step's own {AGENT_LIMIT:?} limit did not end it"
    );
    assert!(
        !journal.contains("preserving shared agent and headless processes"),
        "the daemon was signalled before both servers were up, so the agent steps never ran:\n{journal}"
    );
    assert!(
        journal.contains("shutdown step 'agent session termination' timed out"),
        "the journal does not name the step that ran out of time:\n{journal}"
    );
    assert!(
        journal.contains("shutdown complete"),
        "teardown did not continue past the stalled step:\n{journal}"
    );
}

#[test]
fn a_wedged_teardown_is_ended_by_the_bound_that_lives_off_the_runtime() {
    let host = Host::new();
    let mut daemon = host.start(Some("teardown"), "wedged.log");
    host.await_ready(&daemon);

    let (teardown, code) = daemon.stop();

    // Nothing on the wedged runtime can end this, so a clean exit would mean
    // the wedge never took hold and the test proved nothing.
    assert_ne!(code, Some(0), "a wedged teardown must not report success");
    assert_eq!(code, Some(2), "the hard-exit status changed");
    assert!(
        teardown < SHUTDOWN_BUDGET + SLACK,
        "the wedged daemon took {teardown:?}, over its own {SHUTDOWN_BUDGET:?} budget"
    );
    assert!(
        teardown > SHUTDOWN_BUDGET / 2,
        "the daemon stopped in {teardown:?}, too early for the wedge to have applied"
    );
}

#[test]
fn every_unit_declares_a_stop_timeout_above_the_daemon_budget() {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/install-linux.sh");
    let body = std::fs::read_to_string(&script).expect("scripts/install-linux.sh");
    let declared: Vec<u64> = body
        .lines()
        .filter_map(|line| line.trim().strip_prefix("TimeoutStopSec="))
        .map(|value| value.parse().expect("TimeoutStopSec is written in seconds"))
        .collect();

    let units = body.matches("[Install]").count();
    assert_eq!(
        declared.len(),
        units,
        "a unit without TimeoutStopSec inherits the 90s default, which is the regression"
    );
    for seconds in declared {
        let backstop = Duration::from_secs(seconds);
        assert!(
            backstop > SHUTDOWN_BUDGET,
            "TimeoutStopSec={seconds}s would stop the daemon before its own {SHUTDOWN_BUDGET:?} budget"
        );
        assert!(
            backstop < Duration::from_secs(90),
            "TimeoutStopSec={seconds}s is the distro default this issue was about"
        );
    }
}
