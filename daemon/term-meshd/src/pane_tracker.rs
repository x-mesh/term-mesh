use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct PaneInfo {
    pub cli: String,
    pub cwd: String,
    #[allow(dead_code)]
    pub pid: u32,
    /// Approximate Unix timestamp (seconds) when the process was started.
    /// Derived from `ps -o etime=` (elapsed seconds subtracted from now).
    pub proc_start_unix: i64,
}

/// Maps `TERMMESH_PANEL_ID` → `PaneInfo` by polling live process environments.
/// Every 3 s: `pgrep -x <cli>` → `ps -Eww` (TERMMESH_PANEL_ID) + `ps -o etime=`
/// (start time) → `lsof -a -d cwd` (working directory). macOS-only.
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
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(3));
            interval.tick().await; // skip immediate first tick
            loop {
                interval.tick().await;
                match tokio::task::spawn_blocking(scan_pane_sessions).await {
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

fn scan_pane_sessions() -> HashMap<String, PaneInfo> {
    let mut result = HashMap::new();
    for cli in ["claude", "codex"] {
        let Some(pids) = pgrep(cli) else { continue };
        for pid in pids {
            let Some(panel_id) = read_panel_id(pid) else { continue };
            let Some(cwd) = read_cwd(pid) else { continue };
            let proc_start_unix = read_proc_start_unix(pid).unwrap_or(0);
            result.insert(panel_id, PaneInfo { cli: cli.to_string(), cwd, pid, proc_start_unix });
        }
    }
    result
}

fn pgrep(name: &str) -> Option<Vec<u32>> {
    let output = std::process::Command::new("pgrep")
        .args(["-x", name])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let pids: Vec<u32> = std::str::from_utf8(&output.stdout)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.trim().parse().ok())
        .collect();
    if pids.is_empty() { None } else { Some(pids) }
}

fn parse_panel_id(ps_output: &str) -> Option<String> {
    ps_output
        .split_whitespace()
        .find_map(|token| token.strip_prefix("TERMMESH_PANEL_ID=").map(str::to_string))
}

// SECURITY: ps_output contains the child's full environ (API keys,
// tokens, etc). Extract only the panel_id token — never log or persist
// the raw ps_output.
fn read_panel_id(pid: u32) -> Option<String> {
    let output = std::process::Command::new("ps")
        .args(["-p", &pid.to_string(), "-Eww", "-o", "command="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_panel_id(std::str::from_utf8(&output.stdout).unwrap_or_default())
}

fn read_proc_start_unix(pid: u32) -> Option<i64> {
    // macOS BSD `ps` has no `etimes` keyword (that is GNU/Linux only); it
    // only exposes `etime`, which prints elapsed time as `[[DD-]HH:]MM:SS`.
    let output = std::process::Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "etime="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_etime(std::str::from_utf8(&output.stdout).unwrap_or_default())
}

/// Parse BSD `ps -o etime` output (`[[DD-]HH:]MM:SS`) into an absolute Unix
/// timestamp (now - elapsed_seconds).
fn parse_etime(output: &str) -> Option<i64> {
    let elapsed_secs = parse_etime_seconds(output.trim())?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    Some(now - elapsed_secs)
}

/// Convert a BSD `etime` string (`MM:SS`, `HH:MM:SS`, or `DD-HH:MM:SS`) to
/// total elapsed seconds.
fn parse_etime_seconds(s: &str) -> Option<i64> {
    if s.is_empty() {
        return None;
    }
    // Split optional `DD-` day prefix.
    let (days, hms) = match s.split_once('-') {
        Some((d, rest)) => (d.parse::<i64>().ok()?, rest),
        None => (0, s),
    };
    let parts: Vec<i64> = hms
        .split(':')
        .map(|p| p.parse::<i64>())
        .collect::<Result<_, _>>()
        .ok()?;
    let (h, m, sec) = match parts.as_slice() {
        [m, s] => (0, *m, *s),
        [h, m, s] => (*h, *m, *s),
        _ => return None,
    };
    Some(days * 86400 + h * 3600 + m * 60 + sec)
}

fn read_cwd(pid: u32) -> Option<String> {
    let output = std::process::Command::new("lsof")
        .args(["-p", &pid.to_string(), "-a", "-d", "cwd", "-F", "n"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_cwd(std::str::from_utf8(&output.stdout).unwrap_or_default())
}

// lsof -F n outputs: p<pid>\nfcwd\nn<path>\n
fn parse_cwd(lsof_output: &str) -> Option<String> {
    lsof_output
        .lines()
        .find_map(|line| line.strip_prefix('n').map(str::to_string))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panel_id_extracted_from_ps_output() {
        let ps_out = "/usr/local/bin/claude --dangerously-skip-permissions \
                      TERMMESH_PANEL_ID=550e8400-e29b-41d4-a716-446655440000 \
                      TERMMESH_SOCKET=/tmp/term-meshd.sock TERM_PROGRAM=ghostty";
        assert_eq!(
            parse_panel_id(ps_out).as_deref(),
            Some("550e8400-e29b-41d4-a716-446655440000"),
        );
    }

    #[test]
    fn panel_id_missing_returns_none() {
        let ps_out = "/usr/local/bin/claude TERMMESH_SOCKET=/tmp/term-meshd.sock";
        assert_eq!(parse_panel_id(ps_out), None);
    }

    #[test]
    fn panel_id_first_match_wins() {
        let ps_out = "cmd TERMMESH_PANEL_ID=aaa TERMMESH_PANEL_ID=bbb";
        assert_eq!(parse_panel_id(ps_out).as_deref(), Some("aaa"));
    }

    #[test]
    fn cwd_extracted_from_lsof_output() {
        let lsof_out = "p1234\nfcwd\nn/Users/jinwoo/work/project/term-mesh\n";
        assert_eq!(
            parse_cwd(lsof_out).as_deref(),
            Some("/Users/jinwoo/work/project/term-mesh"),
        );
    }

    #[test]
    fn cwd_empty_output_returns_none() {
        assert_eq!(parse_cwd(""), None);
    }

    #[test]
    fn etime_seconds_parses_all_bsd_formats() {
        assert_eq!(parse_etime_seconds("05:07"), Some(307)); // MM:SS
        assert_eq!(parse_etime_seconds("00:00"), Some(0));
        assert_eq!(parse_etime_seconds("01:02:03"), Some(3723)); // HH:MM:SS
        assert_eq!(parse_etime_seconds("2-03:04:05"), Some(183845)); // DD-HH:MM:SS
    }

    #[test]
    fn etime_seconds_invalid_returns_none() {
        assert_eq!(parse_etime_seconds(""), None);
        assert_eq!(parse_etime_seconds("abc"), None);
        assert_eq!(parse_etime_seconds("12"), None); // single field, no colon
    }

    #[test]
    fn etime_zero_means_just_started() {
        // etime=00:00 → proc_start_unix ≈ now (within a few seconds)
        let result = parse_etime("00:00");
        assert!(result.is_some());
        let start = result.unwrap();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        assert!((now - start).abs() < 5, "proc_start should be within 5s of now");
    }

    #[test]
    fn etime_invalid_returns_none() {
        assert_eq!(parse_etime(""), None);
        assert_eq!(parse_etime("abc"), None);
    }

    #[test]
    fn snapshot_initially_empty() {
        let tracker = PaneTracker::new();
        assert!(tracker.snapshot().is_empty());
    }
}
