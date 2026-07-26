use std::collections::HashMap;
use std::ffi::OsString;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

#[derive(Debug, Clone)]
pub struct PaneInfo {
    pub cli: String,
    pub cwd: String,
    pub pid: u32,
    /// Approximate Unix timestamp (seconds) when the process was started.
    /// Read directly from the process table.
    pub proc_start_unix: i64,
}

/// Maps `TERMMESH_PANEL_ID` → `PaneInfo` by polling live process environments.
/// A single sysinfo refresh replaces the former `2 + 3N` subprocesses
/// (`pgrep`, `ps`, and `lsof`) spawned every three seconds.
#[derive(Clone)]
pub struct PaneTracker {
    state: Arc<Mutex<HashMap<String, PaneInfo>>>,
}

impl PaneTracker {
    pub fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Spawns the background poll loop. Returns self for chaining.
    pub fn start(self) -> Self {
        let state = self.state.clone();
        let system = Arc::new(Mutex::new(System::new()));
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(3));
            interval.tick().await; // skip immediate first tick
            loop {
                interval.tick().await;
                let system = system.clone();
                match tokio::task::spawn_blocking(move || {
                    let mut system = system.lock().unwrap();
                    scan_pane_sessions(&mut system)
                })
                .await
                {
                    Ok(map) => *state.lock().unwrap() = map,
                    Err(e) => tracing::debug!("pane_tracker.scan panicked: {e}"),
                }
            }
        });
        self
    }

    pub fn snapshot(&self) -> HashMap<String, PaneInfo> {
        self.state.lock().unwrap().clone()
    }
}

fn scan_pane_sessions(system: &mut System) -> HashMap<String, PaneInfo> {
    // First discover the process roster without paying to fetch environment
    // and cwd for unrelated processes.
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet),
    );
    let targets: Vec<(Pid, String)> = system
        .processes()
        .iter()
        .filter_map(|(pid, process)| cli_name(process).map(|cli| (*pid, cli.to_string())))
        .collect();

    let target_pids: Vec<Pid> = targets.iter().map(|(pid, _)| *pid).collect();
    if target_pids.is_empty() {
        return HashMap::new();
    }

    // sysinfo uses proc_pidinfo/sysctl on macOS for these fields. Refresh only
    // the target CLI processes and always update cwd because a CLI may chdir.
    system.refresh_processes_specifics(
        ProcessesToUpdate::Some(&target_pids),
        false,
        ProcessRefreshKind::nothing()
            .with_cwd(UpdateKind::Always)
            .with_environ(UpdateKind::Always),
    );

    let mut result = HashMap::new();
    for (pid, cli) in targets {
        let Some(process) = system.process(pid) else {
            continue;
        };
        let Some(panel_id) = panel_id_from_environment(process.environ()) else {
            continue;
        };
        let Some(cwd) = process.cwd() else {
            continue;
        };
        result.insert(
            panel_id,
            PaneInfo {
                cli,
                cwd: cwd.to_string_lossy().into_owned(),
                pid: pid.as_u32(),
                proc_start_unix: i64::try_from(process.start_time()).unwrap_or(0),
            },
        );
    }
    result
}

fn cli_name(process: &sysinfo::Process) -> Option<&'static str> {
    let process_name = process.name().to_str();
    let executable_name = process
        .exe()
        .and_then(|path| path.file_name())
        .and_then(|name| name.to_str());
    ["claude", "codex"]
        .into_iter()
        .find(|candidate| process_name == Some(*candidate) || executable_name == Some(*candidate))
}

// SECURITY: process environments contain API keys and tokens. Extract only
// TERMMESH_PANEL_ID; never stringify, log, or persist the full environment.
fn panel_id_from_environment(environment: &[OsString]) -> Option<String> {
    environment.iter().find_map(|entry| {
        entry
            .to_str()?
            .strip_prefix("TERMMESH_PANEL_ID=")
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panel_id_extracted_from_environment() {
        let environment = vec![
            OsString::from("PATH=/usr/bin"),
            OsString::from("TERMMESH_PANEL_ID=550e8400-e29b-41d4-a716-446655440000"),
            OsString::from("TERMMESH_SOCKET=/tmp/term-meshd.sock"),
        ];
        assert_eq!(
            panel_id_from_environment(&environment).as_deref(),
            Some("550e8400-e29b-41d4-a716-446655440000"),
        );
    }

    #[test]
    fn panel_id_missing_returns_none() {
        let environment = vec![OsString::from("TERMMESH_SOCKET=/tmp/term-meshd.sock")];
        assert_eq!(panel_id_from_environment(&environment), None);
    }

    #[test]
    fn panel_id_first_match_wins() {
        let environment = vec![
            OsString::from("TERMMESH_PANEL_ID=aaa"),
            OsString::from("TERMMESH_PANEL_ID=bbb"),
        ];
        assert_eq!(
            panel_id_from_environment(&environment).as_deref(),
            Some("aaa")
        );
    }

    #[test]
    fn snapshot_initially_empty() {
        let tracker = PaneTracker::new();
        assert!(tracker.snapshot().is_empty());
    }

    #[test]
    fn scan_finds_named_cli_process_without_shell_commands() {
        let temp = tempfile::tempdir().unwrap();
        let executable = temp.path().join("codex");
        std::fs::copy("/bin/sleep", &executable).unwrap();
        let panel_id = format!("pane-tracker-test-{}", std::process::id());
        let mut child = std::process::Command::new(&executable)
            .arg("5")
            .env("TERMMESH_PANEL_ID", &panel_id)
            .current_dir(temp.path())
            .spawn()
            .unwrap();
        let child_pid = child.id();

        let mut system = System::new();
        let mut found = None;
        for _ in 0..20 {
            let snapshot = scan_pane_sessions(&mut system);
            if let Some(info) = snapshot.get(&panel_id) {
                found = Some(info.clone());
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let diagnostic = system
            .process(Pid::from_u32(child_pid))
            .map(|process| {
                format!(
                    "name={:?} exe={:?} cwd={:?} env_count={}",
                    process.name(),
                    process.exe(),
                    process.cwd(),
                    process.environ().len()
                )
            })
            .unwrap_or_else(|| "process missing".to_string());
        let _ = child.kill();
        let _ = child.wait();

        let info = found.unwrap_or_else(|| {
            panic!("sysinfo should discover the named codex process: {diagnostic}")
        });
        assert_eq!(info.cli, "codex");
        assert_eq!(info.cwd, temp.path().to_string_lossy());
        assert!(info.proc_start_unix > 0);
    }
}
