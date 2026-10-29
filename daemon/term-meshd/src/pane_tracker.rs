use std::collections::{HashMap, HashSet};
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
        let scanner = Arc::new(Mutex::new(PaneScanner::new()));
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(3));
            interval.tick().await; // skip immediate first tick
            loop {
                interval.tick().await;
                let scanner = scanner.clone();
                match tokio::task::spawn_blocking(move || scanner.lock().unwrap().scan()).await {
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

/// Incremental process scanner.
///
/// Refreshing every process on each tick costs about 30 ms of CPU for a
/// ~900-process table, almost all of it spent on processes that can never be
/// a pane CLI. The pid list is one cheap call, and a process keeps its name
/// and executable path for its whole life (the full refresh never rewrote
/// them either), so each pid is classified once, when it first appears.
struct PaneScanner {
    system: System,
    /// Every live pid that has already been classified.
    inspected: HashSet<u32>,
    /// The subset of `inspected` that is a `claude` or `codex` CLI.
    targets: HashMap<Pid, &'static str>,
}

/// Splits a fresh pid list into pids not seen before and pids that went away.
fn diff_roster(live: &HashSet<u32>, inspected: &HashSet<u32>) -> (Vec<u32>, Vec<u32>) {
    let appeared = live.difference(inspected).copied().collect();
    let gone = inspected.difference(live).copied().collect();
    (appeared, gone)
}

impl PaneScanner {
    fn new() -> Self {
        Self {
            system: System::new(),
            inspected: HashSet::new(),
            targets: HashMap::new(),
        }
    }

    fn scan(&mut self) -> HashMap<String, PaneInfo> {
        match list_pids() {
            Some(live) => self.update_roster(&live),
            // Without a pid list, fall back to refreshing the whole table.
            None => self.rebuild_roster(),
        }
        self.collect_panes()
    }

    fn update_roster(&mut self, live: &HashSet<u32>) {
        let (appeared, gone) = diff_roster(live, &self.inspected);
        if !gone.is_empty() {
            for pid in &gone {
                self.inspected.remove(pid);
                self.targets.remove(&Pid::from_u32(*pid));
            }
            // Drop the dead entries so the table does not grow without bound.
            let gone: Vec<Pid> = gone.into_iter().map(Pid::from_u32).collect();
            self.system.refresh_processes_specifics(
                ProcessesToUpdate::Some(&gone),
                true,
                ProcessRefreshKind::nothing(),
            );
        }
        if appeared.is_empty() {
            return;
        }
        let appeared: Vec<Pid> = appeared.into_iter().map(Pid::from_u32).collect();
        self.system.refresh_processes_specifics(
            ProcessesToUpdate::Some(&appeared),
            false,
            ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet),
        );
        for pid in appeared {
            self.inspected.insert(pid.as_u32());
            if let Some(cli) = self.system.process(pid).and_then(cli_name) {
                self.targets.insert(pid, cli);
            }
        }
    }

    fn rebuild_roster(&mut self) {
        self.system.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet),
        );
        self.inspected.clear();
        self.targets.clear();
        for (pid, process) in self.system.processes() {
            self.inspected.insert(pid.as_u32());
            if let Some(cli) = cli_name(process) {
                self.targets.insert(*pid, cli);
            }
        }
    }

    fn collect_panes(&mut self) -> HashMap<String, PaneInfo> {
        let system = &mut self.system;
        let targets: Vec<(Pid, String)> = self
            .targets
            .iter()
            .map(|(pid, cli)| (*pid, (*cli).to_string()))
            .collect();

        let target_pids: Vec<Pid> = targets.iter().map(|(pid, _)| *pid).collect();
        if target_pids.is_empty() {
            return HashMap::new();
        }

        // sysinfo uses proc_pidinfo/sysctl on macOS for these fields. Refresh only
        // the target CLI processes and always update cwd because a CLI may chdir.
        let refresh_kind = ProcessRefreshKind::nothing().with_cwd(UpdateKind::Always);
        #[cfg(not(target_os = "macos"))]
        let refresh_kind = refresh_kind.with_environ(UpdateKind::Always);
        system.refresh_processes_specifics(
            ProcessesToUpdate::Some(&target_pids),
            false,
            refresh_kind,
        );

        let mut result = HashMap::new();
        for (pid, cli) in targets {
            let Some(process) = system.process(pid) else {
                continue;
            };
            let Some(panel_id) = process_panel_id(pid, process.environ()) else {
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
}

/// Lists every live pid with one call.
#[cfg(target_os = "macos")]
fn list_pids() -> Option<HashSet<u32>> {
    // SAFETY: a null buffer asks proc_listallpids for the size it needs.
    let needed = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if needed <= 0 {
        return None;
    }
    // The call reports a pid count. Leave room for processes that start
    // between the two calls.
    let capacity = usize::try_from(needed).ok()? + 64;
    let mut pids = vec![0 as libc::pid_t; capacity];
    let buffer_bytes = libc::c_int::try_from(capacity * std::mem::size_of::<libc::pid_t>()).ok()?;
    // SAFETY: `pids` owns `buffer_bytes` writable bytes.
    let written = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), buffer_bytes) };
    if written <= 0 {
        return None;
    }
    let count = usize::try_from(written).ok()?.min(capacity);
    Some(
        pids[..count]
            .iter()
            .filter_map(|pid| u32::try_from(*pid).ok().filter(|pid| *pid > 0))
            .collect(),
    )
}

#[cfg(not(target_os = "macos"))]
fn list_pids() -> Option<HashSet<u32>> {
    let entries = std::fs::read_dir("/proc").ok()?;
    Some(
        entries
            .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse::<u32>().ok())
            .collect(),
    )
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

#[cfg(target_os = "macos")]
fn process_panel_id(pid: Pid, _environment: &[OsString]) -> Option<String> {
    let procargs = macos_process_arguments(pid.as_u32())?;
    panel_id_from_macos_procargs(&procargs)
}

#[cfg(not(target_os = "macos"))]
fn process_panel_id(_pid: Pid, environment: &[OsString]) -> Option<String> {
    panel_id_from_environment(environment)
}

/// Reads one process's argv/environment directly from the macOS kernel.
///
/// `sysinfo` 0.33 exposes an empty `Process::environ()` on some macOS
/// versions, so candidate CLI processes need this narrow syscall fallback.
/// The returned buffer is kept local and is never logged.
#[cfg(target_os = "macos")]
fn macos_process_arguments(pid: u32) -> Option<Vec<u8>> {
    let mut mib = [
        libc::CTL_KERN,
        libc::KERN_PROCARGS2,
        libc::c_int::try_from(pid).ok()?,
    ];
    let mut size: libc::size_t = 0;
    // SAFETY: the first sysctl call only writes the required buffer size.
    if unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } != 0
        || size < std::mem::size_of::<libc::c_int>()
    {
        return None;
    }

    let mut buffer = vec![0_u8; size];
    // SAFETY: `buffer` owns `size` writable bytes and sysctl updates `size`
    // to the number of initialized bytes.
    if unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return None;
    }
    buffer.truncate(size);
    Some(buffer)
}

#[cfg(target_os = "macos")]
fn panel_id_from_macos_procargs(data: &[u8]) -> Option<String> {
    let argc_bytes: [u8; std::mem::size_of::<libc::c_int>()] = data
        .get(..std::mem::size_of::<libc::c_int>())?
        .try_into()
        .ok()?;
    let argc = libc::c_int::from_ne_bytes(argc_bytes);
    if !(0..=4096).contains(&argc) {
        return None;
    }

    let mut offset = std::mem::size_of::<libc::c_int>();
    skip_nul_terminated(data, &mut offset)?; // executable path
    skip_nuls(data, &mut offset);
    for _ in 0..argc {
        skip_nul_terminated(data, &mut offset)?;
        skip_nuls(data, &mut offset);
    }

    const PREFIX: &[u8] = b"TERMMESH_PANEL_ID=";
    while offset < data.len() {
        skip_nuls(data, &mut offset);
        if offset >= data.len() {
            break;
        }
        let end = data[offset..]
            .iter()
            .position(|byte| *byte == 0)
            .map(|relative| offset + relative)
            .unwrap_or(data.len());
        let entry = &data[offset..end];
        if let Some(value) = entry.strip_prefix(PREFIX).filter(|value| !value.is_empty()) {
            return std::str::from_utf8(value).ok().map(str::to_string);
        }
        offset = end.saturating_add(1);
    }
    None
}

#[cfg(target_os = "macos")]
fn skip_nul_terminated(data: &[u8], offset: &mut usize) -> Option<()> {
    let relative = data.get(*offset..)?.iter().position(|byte| *byte == 0)?;
    *offset += relative + 1;
    Some(())
}

#[cfg(target_os = "macos")]
fn skip_nuls(data: &[u8], offset: &mut usize) {
    while data.get(*offset) == Some(&0) {
        *offset += 1;
    }
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
    fn pane_tracker_fixture_process() {
        if std::env::var_os("TERMMESH_PANE_TRACKER_FIXTURE").is_some() {
            std::thread::sleep(Duration::from_secs(5));
        }
    }

    #[test]
    fn scan_finds_named_cli_process_without_shell_commands() {
        let temp = tempfile::tempdir().unwrap();
        let executable = temp.path().join("codex");
        std::os::unix::fs::symlink(std::env::current_exe().unwrap(), &executable).unwrap();
        let panel_id = format!("pane-tracker-test-{}", std::process::id());
        let mut child = std::process::Command::new(&executable)
            .args([
                "--exact",
                "pane_tracker::tests::pane_tracker_fixture_process",
                "--nocapture",
            ])
            .env("TERMMESH_PANE_TRACKER_FIXTURE", "1")
            .env("TERMMESH_PANEL_ID", &panel_id)
            .current_dir(temp.path())
            .spawn()
            .unwrap();
        let child_pid = child.id();

        let mut scanner = PaneScanner::new();
        let mut found = None;
        for _ in 0..20 {
            let snapshot = scanner.scan();
            if let Some(info) = snapshot.get(&panel_id) {
                found = Some(info.clone());
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let diagnostic = scanner
            .system
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
        assert_eq!(
            info.cwd,
            temp.path().canonicalize().unwrap().to_string_lossy()
        );
        assert!(info.proc_start_unix > 0);
    }

    #[test]
    fn diff_roster_reports_appeared_and_gone_pids() {
        let live: HashSet<u32> = [1, 2, 4].into_iter().collect();
        let inspected: HashSet<u32> = [2, 3].into_iter().collect();
        let (mut appeared, mut gone) = diff_roster(&live, &inspected);
        appeared.sort_unstable();
        gone.sort_unstable();
        assert_eq!(appeared, vec![1, 4]);
        assert_eq!(gone, vec![3]);
    }

    #[test]
    fn list_pids_includes_this_process() {
        let pids = list_pids().expect("pid list");
        assert!(pids.contains(&std::process::id()));
    }

    #[test]
    fn scan_tracks_a_cli_that_starts_and_exits_between_scans() {
        let temp = tempfile::tempdir().unwrap();
        let executable = temp.path().join("claude");
        std::os::unix::fs::symlink(std::env::current_exe().unwrap(), &executable).unwrap();
        let panel_id = format!("pane-tracker-churn-{}", std::process::id());

        let mut scanner = PaneScanner::new();
        assert!(!scanner.scan().contains_key(&panel_id));

        let mut child = std::process::Command::new(&executable)
            .args([
                "--exact",
                "pane_tracker::tests::pane_tracker_fixture_process",
                "--nocapture",
            ])
            .env("TERMMESH_PANE_TRACKER_FIXTURE", "1")
            .env("TERMMESH_PANEL_ID", &panel_id)
            .current_dir(temp.path())
            .spawn()
            .unwrap();
        let child_pid = child.id();

        let mut seen = false;
        for _ in 0..40 {
            if scanner.scan().get(&panel_id).map(|info| info.cli.as_str()) == Some("claude") {
                seen = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = child.kill();
        let _ = child.wait();
        assert!(
            seen,
            "a CLI that appears after the first scan must be found"
        );

        let mut gone = false;
        for _ in 0..40 {
            if !scanner.scan().contains_key(&panel_id) {
                gone = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(gone, "an exited CLI must leave the snapshot");
        assert!(!scanner.inspected.contains(&child_pid));
        assert!(!scanner.targets.contains_key(&Pid::from_u32(child_pid)));
    }
}
