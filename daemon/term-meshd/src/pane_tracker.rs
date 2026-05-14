use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct PaneInfo {
    pub cli: String,
    pub cwd: String,
}

/// Maps `TERMMESH_PANEL_ID` → `PaneInfo` by polling live process environments.
/// Every 3 s: `pgrep -x <cli>` → `ps -Eww` (read TERMMESH_PANEL_ID from env)
/// → `lsof -a -d cwd` (read working directory). macOS-only.
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

/// Returns a count of panes per cwd for the given cli type.
/// Used by broadcasters to detect same-cwd collisions (ambiguous attribution).
pub fn count_panes_per_cwd(pane_map: &HashMap<String, PaneInfo>, cli: &str) -> HashMap<String, usize> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for info in pane_map.values() {
        if info.cli == cli {
            *counts.entry(info.cwd.clone()).or_default() += 1;
        }
    }
    counts
}

fn scan_pane_sessions() -> HashMap<String, PaneInfo> {
    let mut result = HashMap::new();
    for cli in ["claude", "codex"] {
        let Some(pids) = pgrep(cli) else { continue };
        for pid in pids {
            let Some(panel_id) = read_panel_id(pid) else { continue };
            let Some(cwd) = read_cwd(pid) else { continue };
            result.insert(panel_id, PaneInfo { cli: cli.to_string(), cwd });
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
    fn snapshot_initially_empty() {
        let tracker = PaneTracker::new();
        assert!(tracker.snapshot().is_empty());
    }

    #[test]
    fn same_cwd_two_panes_counted_as_two() {
        let mut map = HashMap::new();
        map.insert("p1".into(), PaneInfo { cli: "claude".into(), cwd: "/foo".into() });
        map.insert("p2".into(), PaneInfo { cli: "claude".into(), cwd: "/foo".into() });
        map.insert("p3".into(), PaneInfo { cli: "claude".into(), cwd: "/bar".into() });
        let counts = count_panes_per_cwd(&map, "claude");
        assert_eq!(counts.get("/foo").copied().unwrap_or(0), 2); // skip guard triggers
        assert_eq!(counts.get("/bar").copied().unwrap_or(0), 1); // single pane → emit
    }

    #[test]
    fn different_cli_excluded_from_count() {
        let mut map = HashMap::new();
        map.insert("p1".into(), PaneInfo { cli: "codex".into(), cwd: "/foo".into() });
        map.insert("p2".into(), PaneInfo { cli: "codex".into(), cwd: "/foo".into() });
        // Counting for "claude" should not see codex panes
        let counts = count_panes_per_cwd(&map, "claude");
        assert!(counts.is_empty());
    }
}
