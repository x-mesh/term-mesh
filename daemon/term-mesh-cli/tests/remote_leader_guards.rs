use std::io::{ErrorKind, Read};
use std::os::unix::net::UnixListener;
use std::process::{Command, Output};
use std::time::Duration;

const REJECTION: &str = "is not allowed from a scoped remote leader";

struct Run {
    output: Output,
    connections: usize,
    request_bytes: usize,
}

fn run_as_remote_leader(args: &[&str]) -> Run {
    let dir = tempfile::tempdir().expect("tempdir");
    let sock = dir.path().join("app.sock");
    let listener = UnixListener::bind(&sock).expect("bind app socket");

    // No route file and a HOME without `.term-mesh/agent-routes`, so the
    // five plain variables are the route.
    let output = Command::new(env!("CARGO_BIN_EXE_tm-agent"))
        .args(args)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("HOME", dir.path())
        .env("TMPDIR", dir.path())
        .env("TERMMESH_SOCKET", &sock)
        .env("TERMMESH_TEAM", "remote-team")
        .env("TERMMESH_LEADER_GRANT_ID", "11".repeat(32))
        .env("TERMMESH_LEADER_PEER_ID", "ef".repeat(16))
        .env("TERMMESH_LEADER_PROJECT_ID", "name:remote-project")
        .env("TERMMESH_LEADER_TEAM_UUID", "remote-team-uuid")
        .env("TERMMESH_LEADER_EXPIRES_AT", "4102444800")
        .output()
        .expect("run tm-agent");

    listener.set_nonblocking(true).expect("nonblocking");
    let mut connections = 0;
    let mut request_bytes = 0;
    loop {
        match listener.accept() {
            Ok((mut stream, _)) => {
                connections += 1;
                stream.set_nonblocking(false).expect("blocking stream");
                // macOS refuses the option with EINVAL once the peer has
                // closed, which is the normal case after the child exited.
                let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
                let mut bytes = Vec::new();
                let _ = stream.read_to_end(&mut bytes);
                request_bytes += bytes.len();
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => break,
            Err(error) => panic!("accept: {error}"),
        }
    }
    Run {
        output,
        connections,
        request_bytes,
    }
}

fn assert_rejected_before_any_request(args: &[&str], expected: &str) {
    let run = run_as_remote_leader(args);
    let stdout = String::from_utf8_lossy(&run.output.stdout);
    let stderr = String::from_utf8_lossy(&run.output.stderr);
    assert_eq!(
        run.output.status.code(),
        Some(1),
        "{args:?}\nstdout: {stdout}\nstderr: {stderr}"
    );
    assert!(
        stdout.contains(expected) || stderr.contains(expected),
        "{args:?} must report {expected:?}\nstdout: {stdout}\nstderr: {stderr}"
    );
    assert!(
        run.connections >= 1,
        "socket discovery probes the app socket; zero connections means the \
         test never reached it"
    );
    assert_eq!(
        run.request_bytes, 0,
        "{args:?} wrote a request to the peer host's local app\nstderr: {stderr}"
    );
}

#[test]
fn create_is_rejected_before_the_handler_runs() {
    let run = run_as_remote_leader(&["create", "2"]);
    let stderr = String::from_utf8_lossy(&run.output.stderr);
    assert_eq!(
        stderr.trim(),
        format!(
            "Error: team.create {REJECTION}; use the owning project window to \
             change team lifecycle"
        ),
        "only the rejection may run; any other output means the handler did"
    );
    assert_rejected_before_any_request(&["create", "2"], &format!("team.create {REJECTION}"));
}

#[test]
fn destroy_is_rejected_before_the_handler_runs() {
    let run = run_as_remote_leader(&["destroy"]);
    let stderr = String::from_utf8_lossy(&run.output.stderr);
    assert_eq!(
        stderr.trim(),
        format!(
            "Error: team.destroy {REJECTION}; use the owning project window to \
             change team lifecycle"
        ),
        "only the rejection may run; any other output means the handler did"
    );
    assert_rejected_before_any_request(&["destroy"], &format!("team.destroy {REJECTION}"));
}

#[test]
fn raw_team_create_is_rejected_by_the_policy() {
    assert_rejected_before_any_request(
        &["raw", r#"{"method":"team.create","params":{}}"#],
        &format!("team.create {REJECTION}"),
    );
}
